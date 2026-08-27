import Foundation

// MARK: - 协议边界

/// grok 网络边界（OAuth 刷新 + billing 取数；测试注入替身）。
protocol GrokNetworkServicing: AnyObject {
    func postForm(url: URL, body: [String: String]) async throws -> [String: Any]
    func getJSON(url: URL, bearer: String) async throws -> [String: Any]
}

/// URLSession 实现。状态码口径：token 端点 400/401 → reauth；billing
/// 401/403 → reauth，400 → 普通失败（交给 legacy 端点兜底）。
final class GrokURLSessionClient: GrokNetworkServicing {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.session = session
        self.timeout = timeout
    }

    func postForm(url: URL, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(form.utf8)
        return try await perform(request, authStatuses: [400, 401])
    }

    func getJSON(url: URL, bearer: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request, authStatuses: [401, 403])
    }

    private func perform(_ request: URLRequest, authStatuses: Set<Int>) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Grok request failed")
        }
        if authStatuses.contains(http.statusCode) {
            throw LimitError.reauthRequired
        }
        guard http.statusCode == 200 else {
            throw LimitError.network("Grok API returned HTTP \(http.statusCode)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("Grok API returned non-JSON")
        }
        return object
    }
}

// MARK: - 解析纯函数

/// grok billing 归一化 — 纯函数。
enum GrokLimitsParsing {
    /// billing 响应 → 限额窗口；缺 config → nil（未配置）。
    /// 数值字段兼容 `{"val": 123}` 包装形态（unified billing 的响应形状）。
    static func windows(from body: [String: Any]?) -> (primary: UsageWindow?, secondary: UsageWindow?) {
        guard let config = body?["config"] as? [String: Any] else { return (nil, nil) }
        let currentPeriod = config["currentPeriod"] as? [String: Any]
        let resetAt = resetDate(currentPeriod?["end"] as? String)
            ?? resetDate(config["billingPeriodEnd"] as? String)

        var usedPercent = number(config["creditUsagePercent"])
        if usedPercent == nil {
            usedPercent = sumProductUsage(config["productUsage"] as? [[String: Any]])
        }
        let monthlyLimit = number(config["monthlyLimit"])
        let used = number(config["used"])
        if usedPercent == nil, let monthlyLimit, monthlyLimit > 0, let used {
            usedPercent = used / monthlyLimit * 100
        }
        // Unified billing 未用量时省略字段 → 0%，不是解析失败。
        if usedPercent == nil, currentPeriod != nil, (resetAt != nil || resetDate(currentPeriod?["start"] as? String) != nil),
           config["creditUsagePercent"] == nil, config["productUsage"] == nil {
            usedPercent = 0
        }

        var primary: UsageWindow?
        if let usedPercent {
            primary = UsageWindow(
                usedPercent: clamp(usedPercent) ?? 0,
                resetAt: resetAt,
                limit: nil,
                used: nil,
                remaining: nil,
                unit: nil,
                windowSeconds: nil
            )
        }
        var secondary: UsageWindow?
        let onDemandCap = number(config["onDemandCap"])
        let onDemandUsed = number(config["onDemandUsed"])
        if let onDemandCap, onDemandCap > 0, let onDemandUsed {
            secondary = UsageWindow(
                usedPercent: clamp(onDemandUsed / onDemandCap * 100) ?? 0,
                resetAt: resetAt,
                limit: onDemandCap,
                used: onDemandUsed,
                remaining: nil,
                unit: nil,
                windowSeconds: nil
            )
        }
        return (primary, secondary)
    }

    /// 周期类型 → 主窗 kind。类型可能是小写字符串（"monthly"/"weekly"）或
    /// `USAGE_PERIOD_TYPE_*` 枚举（子串匹配）；识别不了时按周期时长推断
    /// （1.5–8 天 → 周，25–35 天 → 月，其余短周期归会话）；最终兜底会话。
    static func primaryWindowKind(from body: [String: Any]?) -> LimitWindowKind {
        let config = body?["config"] as? [String: Any]
        let currentPeriod = config?["currentPeriod"] as? [String: Any]
        let type = (currentPeriod?["type"] as? String)?.lowercased()
        if let type {
            if type.contains("week") { return .weekly }
            if type.contains("month") { return .monthly }
            if type.contains("daily") || type.contains("day") { return .session }
        }
        if let start = resetDate(currentPeriod?["start"] as? String),
           let end = resetDate(currentPeriod?["end"] as? String) {
            let days = end.timeIntervalSince(start) / 86_400
            switch days {
            case 1.5..<8: return .weekly
            case 25..<35: return .monthly
            default: return .session
            }
        }
        return .session
    }

    private static func sumProductUsage(_ productUsage: [[String: Any]]?) -> Double? {
        guard let productUsage, !productUsage.isEmpty else { return nil }
        let sum = productUsage.reduce(0.0) { partial, item in
            partial + (((item["usagePercent"] as? NSNumber)?.doubleValue)
                ?? ((item["usage_percent"] as? NSNumber)?.doubleValue) ?? 0)
        }
        return sum
    }

    /// 数值或 `{"val": <number>}` 包装 → Double。
    private static func number(_ value: Any?) -> Double? {
        if let wrapped = value as? [String: Any], let val = wrapped["val"] as? NSNumber {
            return val.doubleValue
        }
        return (value as? NSNumber)?.doubleValue
    }

    private static func resetDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFractional.date(from: value) ?? isoPlain.date(from: value)
    }

    static func clamp(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}

// MARK: - Fetcher

/// grok 限额（会话/周/月池 + 按需额）：
/// `~/.grok/auth.json`（`GROK_HOME` 覆盖）取 refresh_token + client id（条目
/// `oidc_client_id` 字段或 scope 键 `"<random>::<client-id>"` 后缀）→
/// `auth.x.ai/oauth2/token` 刷新 access token（成功后原子回写 auth.json）→
/// `cli-chat-proxy.grok.com/v1/billing`（`?format=credits` 优先，legacy 兜底；
/// 401 时强制刷新重试一次）。
final class GrokLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .grok

    static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!
    static let billingBaseURL = "https://cli-chat-proxy.grok.com"

    var timeout: TimeInterval = 10
    /// 测试注入：覆盖 grok home 目录（默认 `~/.grok`）。
    var homeOverride: URL?

    private let network: GrokNetworkServicing
    private let fileManager: FileManager

    init(
        network: GrokNetworkServicing = GrokURLSessionClient(),
        fileManager: FileManager = .default
    ) {
        self.network = network
        self.fileManager = fileManager
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 1. 凭证：~/.grok/auth.json 的带 key 条目（或 refresh-token + client id 条目）。
        let home = homeOverride ?? GrokUsageCollector.defaultSessionsDirectory().deletingLastPathComponent()
        let authURL = home.appendingPathComponent("auth.json")
        guard let auth = readAuthEntry(at: authURL) else {
            return nil
        }

        // 2. access key：未过期（缺失视为未过期）直接用；过期且有 refresh 能力 →
        //    刷新并回写；过期但无 refresh 能力 → 沿用旧 key 由 billing 端裁决。
        var refreshedThisRun = false
        var accessKey: String
        if let key = auth.key, !key.isEmpty, !isExpired(auth.expiresAt) {
            accessKey = key
        } else if auth.hasRefreshCapability {
            accessKey = try await refreshAndPersist(entry: auth, at: authURL)
            refreshedThisRun = true
        } else if let key = auth.key, !key.isEmpty {
            accessKey = key
        } else {
            return nil
        }

        // 3. billing；401 且有 refresh 能力且本轮未刷新 → 强制刷新重试一次。
        do {
            let body = try await billingBody(accessToken: accessKey)
            return limits(from: body)
        } catch LimitError.reauthRequired {
            guard !refreshedThisRun, auth.hasRefreshCapability else { throw LimitError.reauthRequired }
            accessKey = try await refreshAndPersist(entry: auth, at: authURL)
            let body = try await billingBody(accessToken: accessKey)
            return limits(from: body)
        }
    }

    private func limits(from body: [String: Any]) -> ProviderUsageLimits? {
        let (primary, secondary) = GrokLimitsParsing.windows(from: body)
        guard primary != nil || secondary != nil else {
            return nil
        }
        var windows: [LimitWindowKind: UsageWindow] = [:]
        if let primary {
            windows[GrokLimitsParsing.primaryWindowKind(from: body)] = primary
        }
        var labeled: [LabeledUsageWindow] = []
        if let secondary {
            labeled.append(LabeledUsageWindow(label: "on-demand", window: secondary))
        }
        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: nil,
            windows: windows,
            labeledWindows: labeled,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }

    private func billingBody(accessToken: String) async throws -> [String: Any] {
        let creditsURL = URL(string: Self.billingBaseURL + "/v1/billing?format=credits")!
        do {
            return try await network.getJSON(url: creditsURL, bearer: accessToken)
        } catch let error as LimitError {
            if error == .reauthRequired { throw error }
        } catch {}
        // legacy 兜底。
        return try await network.getJSON(
            url: URL(string: Self.billingBaseURL + "/v1/billing")!,
            bearer: accessToken
        )
    }

    // MARK: - 刷新与回写

    /// OAuth 刷新 → 新 access key；成功后把新 key / 轮换出的 refresh token /
    /// 过期时间原子回写 auth.json（一次性轮换场景下不回写会让下次刷新失败）。
    private func refreshAndPersist(entry: AuthEntry, at authURL: URL) async throws -> String {
        guard let refreshToken = entry.refreshToken, let clientID = entry.clientID else {
            throw LimitError.reauthRequired
        }
        let tokens = try await network.postForm(url: Self.tokenEndpoint, body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw LimitError.decoding("Grok token endpoint returned no access_token")
        }
        let rotatedRefresh = (tokens["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = parseExpiry(tokens["expires_at"])
            ?? (tokens["expires_in"] as? NSNumber).map {
                Date().addingTimeInterval($0.doubleValue)
            }
        persistTokens(entry: entry, access: access, rotatedRefresh: rotatedRefresh, expiresAt: expiresAt, at: authURL)
        return access
    }

    /// 回写目标条目：新 key、轮换 refresh token；过期时间未知时**删除**旧值
    ///（防止每轮都重复刷新烧掉轮换配额）。其他条目与无关字段原样保留。
    private func persistTokens(entry: AuthEntry, access: String, rotatedRefresh: String?, expiresAt: Date?, at authURL: URL) {
        guard var parsed = readJSONObject(authURL),
              var target = parsed[entry.entryKey] as? [String: Any] else { return }
        target["key"] = access
        if let rotatedRefresh {
            target["refresh_token"] = rotatedRefresh
        }
        if let expiresAt {
            target["expires_at"] = Int(expiresAt.timeIntervalSince1970)
        } else {
            target.removeValue(forKey: "expires_at")
        }
        parsed[entry.entryKey] = target
        guard let data = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let tmpURL = authURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            _ = try fileManager.replaceItemAt(authURL, withItemAt: tmpURL)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
        }
    }

    private func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    // MARK: - auth.json 读取

    private struct AuthEntry {
        var entryKey: String
        var key: String?
        var refreshToken: String?
        var clientID: String?
        var expiresAt: Date?

        /// refresh_token + client id 齐备才具备刷新能力。
        var hasRefreshCapability: Bool {
            (refreshToken?.isEmpty == false) && (clientID?.isEmpty == false)
        }
    }

    private func readAuthEntry(at url: URL) -> AuthEntry? {
        guard let parsed = readJSONObject(url) else { return nil }
        var fallback: AuthEntry?
        for (entryKey, value) in parsed {
            guard let entry = value as? [String: Any] else { continue }
            let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let refreshToken = (entry["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // client id：条目 oidc_client_id 字段优先；scope 键
            //（"<random>::<client-id>"）后缀兜底。
            var clientID = (entry["oidc_client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clientID.isEmpty, entryKey.contains("::") {
                clientID = entryKey.components(separatedBy: "::").last ?? ""
            }
            let candidate = AuthEntry(
                entryKey: entryKey,
                key: key.isEmpty ? nil : key,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                clientID: clientID.isEmpty ? nil : clientID,
                expiresAt: parseExpiry(entry["expires_at"])
            )
            if candidate.key != nil {
                return candidate // 带 access token 的条目直接胜出
            }
            if candidate.hasRefreshCapability, fallback == nil {
                fallback = candidate
            }
        }
        return fallback
    }

    private func parseExpiry(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let ts = number.doubleValue
            return Date(timeIntervalSince1970: ts < 1e12 ? ts : ts / 1000)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    /// 过期判定：缺失视为未过期（直接用旧 key，由 billing 端 401 裁决）。
    private func isExpired(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date <= Date().addingTimeInterval(60)
    }
}
