import CryptoKit
import Foundation

// MARK: - 套餐鉴权候选

/// 单个套餐 provider 的取数候选（由 `~/.zcode/v2` 本地文件推导）。
struct ZcodePlanAuth: Equatable {
    enum PlanKind: Equatable {
        /// coding-plan：走 monitor quota 端点，config.json 明文 key 鉴权。
        case codingPlan
        /// start-plan：走 billing/balance 端点，凭据 JWT（Bearer）。
        case startPlan
    }

    var providerKey: String
    var kind: PlanKind
    /// 鉴权 key：coding-plan 为 config.json 的 provider apiKey；start-plan 为
    /// 凭据 JWT（或 config 同名 provider 的 key 兜底）。
    var apiKey: String
    /// coding-plan quota 端点；start-plan 恒 nil（billing 端点固定）。
    var quotaURL: URL?
}

// MARK: - quota 解析结果

/// quota/limit 响应归一化结果。
struct ZcodeQuotaResult: Equatable {
    var windows: [LimitWindowKind: UsageWindow]
    var labeledWindows: [LabeledUsageWindow]
    var planLabel: String?
}

// MARK: - 解析纯函数

/// zcode billing/quota 归一化与套餐发现 — 纯函数。
enum ZcodeLimitsParsing {
    // MARK: 套餐 tier

    /// 套餐标识 → 展示 tier："zcode-v3-start-plan-0615" → "Start"；
    /// quota 的 level（如 "Max"）保留原文；无已知 tier 词 → nil。
    static func planTier(from planID: String?) -> String? {
        guard let planID, !planID.isEmpty else { return nil }
        let lowered = planID.lowercased()
        for tier in ["lite", "start", "pro", "max", "team", "enterprise"]
        where lowered.range(of: "\\b\(tier)\\b", options: .regularExpression) != nil {
            return tier.prefix(1).uppercased() + tier.dropFirst()
        }
        return nil
    }

    // MARK: billing/balance（start-plan 额度桶）

    /// `data.balances[]` → 按 total 降序的窗口数组（limit/used/remaining/unit）。
    static func windows(from body: [String: Any]?) -> [UsageWindow] {
        let data = body?["data"] as? [String: Any]
        let balances = data?["balances"] as? [[String: Any]] ?? []
        let buckets = balances.compactMap { bucket -> UsageWindow? in
            let total = number(bucket["total_units"])
            let used = number(bucket["used_units"])
            let remaining = number(bucket["remaining_units"])
            guard let total, total > 0, let used else { return nil }
            let resetAt = (number(bucket["period_end"]) ?? number(bucket["expires_at"]))
                .flatMap { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) }
            return UsageWindow(
                usedPercent: min(max(used / total * 100, 0), 100),
                resetAt: resetAt,
                limit: total,
                used: used,
                remaining: remaining,
                unit: "credits",
                windowSeconds: nil
            )
        }
        return buckets.sorted { ($0.limit ?? 0) > ($1.limit ?? 0) }
    }

    /// billing 主桶 plan_id → tier（"start-plan" → "Start"）。
    static func balancePlanLabel(from body: [String: Any]?) -> String? {
        let balances = (body?["data"] as? [String: Any])?["balances"] as? [[String: Any]] ?? []
        return planTier(from: balances.first?["plan_id"] as? String)
    }

    // MARK: 套餐发现（~/.zcode/v2 本地布局）

    /// setting.json 的 `modelProviderFamilySelectedKeys` → 选中的套餐 provider
    /// key（值形如 "coding-plan:builtin:bigmodel-coding-plan"；域键含
    /// providerFamilyDomain）。
    static func selectedPlanProviderKeys(fromSetting setting: [String: Any]?) -> [String] {
        guard let selected = setting?["modelProviderFamilySelectedKeys"] as? [String: Any] else { return [] }
        let domain = (setting?["providerFamilyDomain"] as? String).map { [$0] } ?? []
        let domains = (domain + Array(selected.keys)).filter { !$0.isEmpty }
        var out: [String] = []
        for key in domains {
            guard let raw = selected[key] as? String,
                  let match = raw.range(
                    of: #"builtin:(?:bigmodel|zai)-(?:start|coding)-plan"#,
                    options: .regularExpression
                  )
            else { continue }
            let value = String(raw[match])
            if !out.contains(value) { out.append(value) }
        }
        return out
    }

    /// coding-plan-cache.json 的 `entryStatus.items` → provider key → status。
    static func planProviderAvailability(fromCache cache: [String: Any]?) -> [String: String] {
        let items = (cache?["entryStatus"] as? [String: Any])?["items"] as? [String: Any] ?? [:]
        var out: [String: String] = [:]
        for (key, value) in items {
            if let status = (value as? [String: Any])?["status"] as? String {
                out[key] = status
            }
        }
        return out
    }

    /// 组装取数候选：选中（setting）→ 可用（cache）→ 内置默认，去重后逐个过滤。
    /// 过滤条件：config.json 存在对应 provider 条目且未禁用；cache 有可用性数据
    /// 时仅放行 available。coding-plan 仅认 config.json 明文 key；start-plan 优先
    /// 凭据 JWT（域须与 active_provider 匹配），缺失回落 config key。
    static func authCandidates(
        config: [String: Any]?,
        availability: [String: String],
        selectedKeys: [String],
        activeProvider: String?,
        jwt: String?
    ) -> [ZcodePlanAuth] {
        let defaults = [
            "builtin:bigmodel-start-plan",
            "builtin:zai-start-plan",
            "builtin:bigmodel-coding-plan",
            "builtin:zai-coding-plan",
        ]
        let selected = selectedKeys.filter { defaults.contains($0) }
        let available = defaults.filter { availability[$0] == "available" }
        var ordered: [String] = []
        for key in selected + available + defaults {
            if !ordered.contains(key) { ordered.append(key) }
        }

        let providers = config?["provider"] as? [String: Any] ?? [:]
        let hasAvailability = !availability.isEmpty
        var out: [ZcodePlanAuth] = []
        for key in ordered {
            guard let provider = providers[key] as? [String: Any],
                  (provider["enabled"] as? Bool) != false else { continue }
            if hasAvailability, let status = availability[key], status != "available" { continue }
            let options = provider["options"] as? [String: Any] ?? [:]
            let configKey = (options["apiKey"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasSuffix("coding-plan") {
                guard !configKey.isEmpty,
                      let quotaURL = quotaURL(providerKey: key, options: options) else { continue }
                out.append(ZcodePlanAuth(
                    providerKey: key,
                    kind: .codingPlan,
                    apiKey: configKey,
                    quotaURL: quotaURL
                ))
            } else {
                let domain = key.contains("zai") ? "zai" : "bigmodel"
                let credential = (activeProvider == domain) ? jwt : nil
                guard let apiKey = credential ?? (configKey.isEmpty ? nil : configKey) else { continue }
                out.append(ZcodePlanAuth(
                    providerKey: key,
                    kind: .startPlan,
                    apiKey: apiKey,
                    quotaURL: nil
                ))
            }
        }
        return out
    }

    /// 纯凭据兜底候选：active_provider 为 zai/bigmodel 且 JWT 可用时追加
    /// （config.json 缺 provider 条目时 start-plan 仍可取数）。
    static func credentialFallbackCandidate(activeProvider: String?, jwt: String?) -> ZcodePlanAuth? {
        guard let jwt, !jwt.isEmpty,
              let domain = activeProvider, domain == "zai" || domain == "bigmodel" else { return nil }
        return ZcodePlanAuth(
            providerKey: "builtin:\(domain)-start-plan",
            kind: .startPlan,
            apiKey: jwt,
            quotaURL: nil
        )
    }

    /// coding-plan quota 端点：bigmodel 固定 bigmodel.cn；zai 仅信任 provider
    /// baseURL 的 api.z.ai 域 origin，其余回落 api.z.ai。
    static func quotaURL(providerKey: String, options: [String: Any]) -> URL? {
        let path = "/api/monitor/usage/quota/limit"
        if providerKey.contains("zai") {
            if let baseURL = options["baseURL"] as? String,
               let url = URL(string: baseURL),
               let scheme = url.scheme,
               let host = url.host,
               host == "api.z.ai" || host.hasSuffix(".api.z.ai") {
                return URL(string: "\(scheme)://\(host)\(path)")
            }
            return URL(string: "https://api.z.ai\(path)")
        }
        return URL(string: "https://bigmodel.cn\(path)")
    }

    // MARK: quota/limit（coding-plan 窗口）

    /// quota 响应 → 窗口集合。命名窗口固定映射：`TOKENS_LIMIT(unit=3,number=5)`
    /// → session（5h）、`TOKENS_LIMIT(unit=6)` → weekly、`TIME_LIMIT(unit=5,
    /// number=1)` → labeled("Tools")；命名窗口全缺时通用解析按 number 总量降序
    /// （主桶 credits，其余 labeled secondary/tertiary）。`percentage` 字段直接是
    /// 已用百分比（此场景绝对量口径不可信，不填充 limit/used/remaining）。
    static func quotaResult(from body: [String: Any]?) throws -> ZcodeQuotaResult {
        if let code = UsageWindowParsing.numeric(body?["code"]), code != 0, code != 200 {
            throw LimitError.decoding("ZCode quota API error code=\(Int(code))")
        }
        if (body?["success"] as? Bool) == false {
            throw LimitError.decoding("ZCode quota API error")
        }
        let data = body?["data"] as? [String: Any] ?? [:]
        let limits = data["limits"] as? [[String: Any]] ?? []

        let fiveHour = findQuotaLimit(limits, type: "TOKENS_LIMIT", unit: 3, number: 5)
        let weekly = findQuotaLimit(limits, type: "TOKENS_LIMIT", unit: 6)
        let tools = findQuotaLimit(limits, type: "TIME_LIMIT", unit: 5, number: 1)

        var windows: [LimitWindowKind: UsageWindow] = [:]
        var labeled: [LabeledUsageWindow] = []
        if fiveHour != nil || weekly != nil || tools != nil {
            if let window = quotaWindow(from: fiveHour, windowSeconds: 18000) {
                windows[.session] = window
            }
            if let window = quotaWindow(from: weekly, windowSeconds: 604800) {
                windows[.weekly] = window
            }
            if let window = quotaWindow(from: tools, windowSeconds: nil) {
                labeled.append(LabeledUsageWindow(label: "Tools", window: window))
            }
        } else {
            let parsed = limits
                .compactMap { quotaWindow(from: $0, windowSeconds: nil) }
                .sorted { ($0.limit ?? 0) > ($1.limit ?? 0) }
            if let primary = parsed.first {
                windows[.credits] = primary
            }
            for (index, window) in parsed.enumerated() where index > 0 {
                labeled.append(LabeledUsageWindow(
                    label: index == 1 ? "secondary" : "tertiary",
                    window: window
                ))
            }
        }

        let level = data["level"] as? String
        return ZcodeQuotaResult(
            windows: windows,
            labeledWindows: labeled,
            planLabel: level.flatMap { planTier(from: $0) ?? $0 }
        )
    }

    /// 按类型/单元/序号定位一条 quota limit。
    private static func findQuotaLimit(
        _ limits: [[String: Any]],
        type: String,
        unit: Double,
        number: Double? = nil
    ) -> [String: Any]? {
        limits.first { limit in
            guard limit["type"] as? String == type,
                  UsageWindowParsing.numeric(limit["unit"]) == unit else { return false }
            guard let number else { return true }
            return UsageWindowParsing.numeric(limit["number"]) == number
        }
    }

    /// 单条 quota limit → 窗口；percentage / usage+number / remaining+number 三条
    /// 途径都推不出已用百分比 → nil。
    private static func quotaWindow(from limit: [String: Any]?, windowSeconds: Double?) -> UsageWindow? {
        guard let limit else { return nil }
        let total = UsageWindowParsing.numeric(limit["number"])
        let used = UsageWindowParsing.numeric(limit["usage"])
            ?? UsageWindowParsing.numeric(limit["currentValue"])
        let remaining = UsageWindowParsing.numeric(limit["remaining"])
        let rawPercent = UsageWindowParsing.numeric(limit["percentage"])
        var usedPercent: Double?
        if let rawPercent {
            usedPercent = rawPercent
        } else if let total, total > 0, let used {
            usedPercent = used / total * 100
        } else if let total, total > 0, let remaining, remaining <= total {
            usedPercent = (total - remaining) / total * 100
        }
        guard let usedPercent else { return nil }
        let hasRawPercent = rawPercent != nil
        return UsageWindow(
            usedPercent: min(max(usedPercent, 0), 100),
            resetAt: UsageWindowParsing.parseResetDate(limit["nextResetTime"]),
            limit: hasRawPercent ? nil : total,
            used: hasRawPercent ? nil : used,
            remaining: hasRawPercent ? nil : remaining,
            unit: nil,
            windowSeconds: windowSeconds
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

// MARK: - Fetcher

/// zcode 限额取数：按 `~/.zcode/v2` 本地文件定位当前套餐（setting 选中 →
/// cache 可用 → 内置默认），coding-plan 走 monitor quota 端点（config.json 明文
/// key 鉴权），start-plan 走 `zcode.z.ai` billing/balance（credentials.json 的
/// `zcodejwttoken`，enc:v1 AES-256-GCM 解密或明文）。
///
/// 解密失败/凭证缺失 → 该候选不可用（fail-soft，SPEC R5：私有实现可能漂移，
/// 绝不崩溃）；所有候选耗尽 → nil（未配置）。
final class ZcodeLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .zcode

    static let billingBaseURL = "https://zcode.z.ai/api/v1/zcode-plan"

    var timeout: TimeInterval = 10
    /// 测试注入：覆盖 zcode home 目录（默认 `~/.zcode`）。
    var homeOverride: URL?

    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        let home = homeOverride ?? ZcodeUsageCollector.defaultDatabaseURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // 1. 凭据（start-plan JWT；解密失败仅表示该路径不可用，coding-plan 不依赖）。
        let credentials = loadCredentials(at: home.appendingPathComponent("v2/credentials.json"))

        // 2. 套餐候选 + 纯凭据兜底（去重）。
        var candidates = ZcodeLimitsParsing.authCandidates(
            config: readJSONObject(home.appendingPathComponent("v2/config.json")),
            availability: ZcodeLimitsParsing.planProviderAvailability(
                fromCache: readJSONObject(home.appendingPathComponent("v2/coding-plan-cache.json"))
            ),
            selectedKeys: ZcodeLimitsParsing.selectedPlanProviderKeys(
                fromSetting: readJSONObject(home.appendingPathComponent("v2/setting.json"))
            ),
            activeProvider: credentials?.activeProvider,
            jwt: credentials?.jwt
        )
        if let fallback = ZcodeLimitsParsing.credentialFallbackCandidate(
            activeProvider: credentials?.activeProvider,
            jwt: credentials?.jwt
        ), !candidates.contains(where: { $0.providerKey == fallback.providerKey }) {
            candidates.append(fallback)
        }
        guard !candidates.isEmpty else { return nil }

        // 3. 逐候选取数；成功但无窗口（如 billing 端点对 coding 套餐返回空桶）
        //    → 继续下一候选；全部报错 → 抛第一个（保留 reauth 语义）。
        var firstError: Error?
        for candidate in candidates {
            do {
                if let limits = try await fetchLimits(for: candidate) {
                    return limits
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return nil
    }

    // MARK: 单候选取数

    private func fetchLimits(for candidate: ZcodePlanAuth) async throws -> ProviderUsageLimits? {
        if candidate.kind == .codingPlan, let quotaURL = candidate.quotaURL {
            var request = URLRequest(url: quotaURL)
            request.timeoutInterval = timeout
            // quota 端点鉴权：authorization 头直接放 key，无 Bearer 前缀。
            request.setValue(candidate.apiKey, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let payload = try await jsonBody(for: request, label: "quota")
            let result = try ZcodeLimitsParsing.quotaResult(from: payload)
            guard !result.windows.isEmpty || !result.labeledWindows.isEmpty else { return nil }
            return ProviderUsageLimits(
                provider: provider,
                configured: true,
                subscriptionStatus: .active,
                planLabel: result.planLabel,
                windows: result.windows,
                labeledWindows: result.labeledWindows,
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: nil
            )
        }

        var request = URLRequest(url: URL(string: Self.billingBaseURL + "/billing/balance")!)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(candidate.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload = try await jsonBody(for: request, label: "balance")

        // 3. 窗口：主额度桶 → .credits；次/三桶 → labeled。
        let windows = ZcodeLimitsParsing.windows(from: payload)
        guard !windows.isEmpty else { return nil }
        var primary: [LimitWindowKind: UsageWindow] = [:]
        var labeled: [LabeledUsageWindow] = []
        if let first = windows.first {
            primary[.credits] = first
        }
        for (index, window) in windows.enumerated() where index > 0 {
            let label = index == 1 ? "secondary" : "tertiary"
            labeled.append(LabeledUsageWindow(label: label, window: window))
        }
        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: ZcodeLimitsParsing.balancePlanLabel(from: payload),
            windows: primary,
            labeledWindows: labeled,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }

    /// 发请求并校验：401/403 → reauth；非 200 → network；返回 JSON 对象。
    private func jsonBody(for request: URLRequest, label: String) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("ZCode \(label) request failed")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LimitError.reauthRequired
        }
        guard http.statusCode == 200 else {
            throw LimitError.network("ZCode \(label) API returned HTTP \(http.statusCode)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("ZCode \(label) API returned non-JSON")
        }
        return payload
    }

    // MARK: 凭证读取与解密

    private struct ZcodeCredentials {
        var activeProvider: String?
        var jwt: String?
    }

    private func loadCredentials(at credentialsURL: URL) -> ZcodeCredentials? {
        guard let parsed = readJSONObject(credentialsURL) else { return nil }
        let active = decrypted(parsed["oauth:active_provider"])
        let jwt = decrypted(parsed["zcodejwttoken"])
        return ZcodeCredentials(
            activeProvider: active,
            jwt: (jwt?.isEmpty == false) ? jwt : nil
        )
    }

    /// enc:v1 解密（AES-256-GCM，密钥 = sha256(secret)）或明文直通；失败 → nil。
    /// secret 的 home 段是**用户主目录**（写入侧与 ZCODE_HOME 覆盖无关）；载荷
    /// 分段为 base64url 无 padding（兼容标准 base64）。
    private func decrypted(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        guard value.hasPrefix("enc:v1:") else { return value }
        let parts = value.dropFirst("enc:v1:".count).split(separator: ".")
        guard parts.count == 3,
              let iv = Self.base64Decoded(parts[0]),
              let tag = Self.base64Decoded(parts[1]),
              let encrypted = Self.base64Decoded(parts[2]) else {
            return nil
        }
        let secret = "zcode-credential-fallback:\(Self.hostPlatform):\(Self.credentialHome):\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: encrypted,
            tag: tag
        ), let decrypted = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        let string = String(data: decrypted, encoding: .utf8) ?? ""
        return string.isEmpty ? nil : string
    }

    /// 凭据 secret 的 home 段：真实用户主目录。
    private static var credentialHome: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static var hostPlatform: String {
        #if os(macOS)
        "darwin"
        #else
        "linux"
        #endif
    }

    /// base64url / 标准 base64 统一解码：字母表归一后重排 padding。
    private static func base64Decoded(_ encoded: Substring) -> Data? {
        var standard = String(encoded)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        while standard.count % 4 != 0 { standard += "=" }
        return Data(base64Encoded: standard)
    }

    // MARK: 本地文件读取

    private func readJSONObject(_ url: URL) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
