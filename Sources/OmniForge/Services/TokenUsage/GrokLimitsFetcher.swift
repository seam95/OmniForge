import Foundation

// MARK: - 协议边界

/// grok 网络边界（OAuth 刷新 + billing 取数；测试注入替身）。
protocol GrokNetworkServicing: AnyObject {
    func postForm(url: URL, body: [String: String]) async throws -> [String: Any]
    func getJSON(url: URL, bearer: String) async throws -> [String: Any]
}

/// URLSession 实现。
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
        return try await perform(request)
    }

    func getJSON(url: URL, bearer: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Grok request failed")
        }
        if http.statusCode == 401 || http.statusCode == 400 {
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

/// grok billing 归一化 — 纯函数（参考 normalizeGrokBillingResponse）。
enum GrokLimitsParsing {
    /// billing 响应 → 限额窗口；缺 config → nil（未配置）。
    static func windows(from body: [String: Any]?) -> (primary: UsageWindow?, secondary: UsageWindow?) {
        guard let config = body?["config"] as? [String: Any] else { return (nil, nil) }
        let currentPeriod = config["currentPeriod"] as? [String: Any]
        let resetAt = resetDate(currentPeriod?["end"] as? String)
            ?? resetDate(config["billingPeriodEnd"] as? String)
        let periodType = (currentPeriod?["type"] as? String)?.lowercased()

        var usedPercent = clamp(config["creditUsagePercent"] as? Double)
        if usedPercent == nil {
            usedPercent = sumProductUsage(config["productUsage"] as? [[String: Any]])
        }
        let monthlyLimit = (config["monthlyLimit"] as? NSNumber)?.doubleValue
        let used = (config["used"] as? NSNumber)?.doubleValue
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
        let onDemandCap = (config["onDemandCap"] as? NSNumber)?.doubleValue
        let onDemandUsed = (config["onDemandUsed"] as? NSNumber)?.doubleValue
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
        _ = periodType
        return (primary, secondary)
    }

    /// 周期类型 → 窗口 kind（primary 窗）。
    static func primaryWindowKind(from body: [String: Any]?) -> LimitWindowKind {
        let config = body?["config"] as? [String: Any]
        let type = (config?["currentPeriod"] as? [String: Any])?["type"] as? String
        switch type?.lowercased() {
        case "monthly": return .monthly
        case "weekly": return .weekly
        default: return .session
        }
    }

    private static func sumProductUsage(_ productUsage: [[String: Any]]?) -> Double? {
        guard let productUsage, !productUsage.isEmpty else { return nil }
        let sum = productUsage.reduce(0.0) { partial, item in
            partial + (((item["usagePercent"] as? NSNumber)?.doubleValue)
                ?? ((item["usage_percent"] as? NSNumber)?.doubleValue) ?? 0)
        }
        return sum
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
/// `~/.grok/auth.json`（`GROK_HOME` 覆盖）取 refresh_token + oidc_client_id →
/// `auth.x.ai/oauth2/token` 刷新 access token → `cli-chat-proxy.grok.com/v1/billing`
/// （`?format=credits` 优先，legacy 兜底）。
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

        // 2. access token：未过期直接用；过期/缺失 → OAuth 刷新。
        let accessToken: String
        if let key = auth.key, !key.isEmpty, !isExpired(auth.expiresAt) {
            accessToken = key
        } else {
            guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty,
                  let clientID = auth.clientID, !clientID.isEmpty else {
                return nil
            }
            let tokens = try await network.postForm(url: Self.tokenEndpoint, body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ])
            guard let refreshed = tokens["access_token"] as? String, !refreshed.isEmpty else {
                return nil
            }
            accessToken = refreshed
        }

        // 3. billing（credits 格式优先，legacy 兜底）。
        let body = try await billingBody(accessToken: accessToken)
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

    // MARK: - auth.json 读取

    private struct AuthEntry {
        var key: String?
        var refreshToken: String?
        var clientID: String?
        var expiresAt: Date?
    }

    private func readAuthEntry(at url: URL) -> AuthEntry? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var fallback: AuthEntry?
        for (_, value) in parsed {
            guard let entry = value as? [String: Any] else { continue }
            let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let refreshToken = (entry["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clientID = (entry["oidc_client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let candidate = AuthEntry(
                key: key.isEmpty ? nil : key,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                clientID: clientID.isEmpty ? nil : clientID,
                expiresAt: parseExpiry(entry["expires_at"])
            )
            if candidate.key != nil {
                return candidate // 带 access token 的条目直接胜出
            }
            if candidate.refreshToken != nil, candidate.clientID != nil, fallback == nil {
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

    private func isExpired(_ date: Date?) -> Bool {
        guard let date else { return true }
        return date <= Date().addingTimeInterval(60)
    }
}