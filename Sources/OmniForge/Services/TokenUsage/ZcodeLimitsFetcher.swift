import CryptoKit
import Foundation

// MARK: - 套餐鉴权候选

/// 单个套餐 provider 的取数候选（由 `~/.zcode/v2` 本地文件推导）。
struct ZcodePlanAuth: Equatable {
    enum PlanKind: Equatable {
        /// coding-plan：走 monitor quota 端点。凭据二选一：
        /// ① project token 链路（当前布局，`projectLocation` + `loginToken`）；
        /// ② config.json 明文 key（旧布局兼容）。
        case codingPlan
        /// start-plan：走 billing/balance 端点，凭据 JWT（Bearer）。
        case startPlan
    }

    var providerKey: String
    var kind: PlanKind
    /// 鉴权 key：coding-plan 为 project token 或 config.json 明文 key；
    /// start-plan 为凭据 JWT（或 config 同名 provider 的 key 兜底）。
    var apiKey: String
    /// coding-plan quota 端点；start-plan 恒 nil（billing 端点固定）。
    var quotaURL: URL?
    /// coding-plan 的 project key 定位（需要换取 project token 时非 nil）。
    var projectLocation: ZcodeProjectKeyLocation?
    /// coding-plan 的 project key 三元组（organizationId / projectId / apiKeyId）。
    var projectMaterial: ZcodeProjectKeyMaterial?
    /// 换取 project token 用的 OAuth access token（`oauth:{family}:access_token`）。
    var loginToken: String?
}

/// `credentials.json` 的 key 名 `project-key-location:v1:<urlencoded JSON>` 解析结果。
struct ZcodeProjectKeyLocation: Equatable {
    /// 取数域 origin（如 `https://bigmodel.cn`）。
    var origin: String
    /// 域族：`bigmodel` / `zai`。
    var family: String
    /// 团队套餐标记；个人套餐为 nil。
    var team: Bool
}

/// project key 值（`enc:v1` 解密后）的字段子集。
struct ZcodeProjectKeyMaterial: Equatable {
    var organizationId: String
    var projectId: String
    var apiKeyId: String
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

    /// 当前布局：`providerFamilyConnectionSelections` 的 `{family: {kind}}` →
    /// 选中套餐 provider key。
    ///
    /// kind 三态映射：`start-plan` → start-plan 候选，`individual-coding-plan` →
    /// coding-plan 候选，`team-coding-plan` 本期不支持取数（需要组织/项目/产品
    /// 三元组且成员席位校验复杂），识别后跳过。
    static func connectionSelectedKeys(fromSetting setting: [String: Any]?) -> [String] {
        guard let selections = setting?["providerFamilyConnectionSelections"] as? [String: Any]
        else { return [] }
        var out: [String] = []
        for (family, raw) in selections {
            guard family == "bigmodel" || family == "zai",
                  let kind = (raw as? [String: Any])?["kind"] as? String
            else { continue }
            let key: String?
            switch kind {
            case "start-plan":
                key = "builtin:\(family)-start-plan"
            case "individual-coding-plan":
                key = "builtin:\(family)-coding-plan"
            default:
                // team-coding-plan 及未知 kind：本期不取数。
                key = nil
            }
            if let key, !out.contains(key) { out.append(key) }
        }
        return out.sorted()
    }

    // MARK: project key（当前布局的 coding-plan 凭据来源）

    /// `credentials.json` 中 `project-key-location` 键名的前缀。
    static let projectKeyLocationPrefix = "project-key-location:v1:"

    /// 解析 `project-key-location:v1:<urlencoded JSON>` 键名。
    /// JSON 形状：`[origin, family, accountId, team, scope, projectSelection]`。
    static func projectKeyLocation(fromKey key: String) -> ZcodeProjectKeyLocation? {
        guard key.hasPrefix(projectKeyLocationPrefix) else { return nil }
        let encoded = String(key.dropFirst(projectKeyLocationPrefix.count))
        guard let decoded = encoded.removingPercentEncoding,
              let data = decoded.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let origin = array[0] as? String,
              let family = array[1] as? String,
              family == "bigmodel" || family == "zai",
              !origin.isEmpty
        else { return nil }
        // 数组第 4 项（索引 3）为 team 描述对象或 null。
        let team = !(array[3] is NSNull) && array[3] != nil
        return ZcodeProjectKeyLocation(origin: origin, family: family, team: team)
    }

    /// 解析 project key 值（`enc:v1` 解密后）→ 三元组；任一字段缺失即 nil。
    static func projectKeyMaterial(fromValue value: Any?) -> ZcodeProjectKeyMaterial? {
        guard let object = value as? [String: Any] else { return nil }
        func field(_ name: String) -> String? {
            guard let raw = object[name] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let organizationId = field("organizationId"),
              let projectId = field("projectId"),
              let apiKeyId = field("apiKeyId")
        else { return nil }
        return ZcodeProjectKeyMaterial(
            organizationId: organizationId,
            projectId: projectId,
            apiKeyId: apiKeyId
        )
    }

    /// project token 签发请求的 URL：
    /// `{origin}/api/biz/v1/organization/{org}/projects/{proj}/api_keys/{keyId}/access_tokens`
    static func projectAccessTokenURL(location: ZcodeProjectKeyLocation,
                                      material: ZcodeProjectKeyMaterial) -> URL? {
        func encode(_ value: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let origin = location.origin.hasSuffix("/")
            ? String(location.origin.dropLast())
            : location.origin
        let path = "/api/biz/v1/organization/\(encode(material.organizationId))"
            + "/projects/\(encode(material.projectId))"
            + "/api_keys/\(encode(material.apiKeyId))/access_tokens"
        return URL(string: origin + path)
    }

    /// coding-plan quota 端点（按 origin 拼 `/api/monitor/usage/quota/limit`）。
    static func projectQuotaURL(origin: String) -> URL? {
        let base = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        return URL(string: base + "/api/monitor/usage/quota/limit")
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

    /// 当前布局的 coding-plan 候选：由 `credentials.json` 的 project key 推导。
    ///
    /// 每条 `project-key-location:v1:` 条目提供 origin/family，值（解密后）提供
    /// 组织/项目/密钥三元组；换取 project token 还需同域 OAuth access token。
    /// 三者齐备才产出候选，缺一即跳过（fail-soft）。
    ///
    /// - Parameters:
    ///   - entries: 键名 → 解密后的值（明文 JSON 字符串）。
    ///   - selectedKeys: 选中的套餐 provider key（`builtin:{family}-coding-plan`）。
    ///   - accessToken: 域 → OAuth access token。
    static func projectKeyCandidates(
        entries: [(key: String, value: String)],
        selectedKeys: [String],
        accessTokens: [String: String]
    ) -> [ZcodePlanAuth] {
        var out: [ZcodePlanAuth] = []
        for entry in entries {
            guard let location = projectKeyLocation(fromKey: entry.key) else { continue }
            // 团队套餐需要成员席位，本期不取数。
            guard !location.team else { continue }
            let providerKey = "builtin:\(location.family)-coding-plan"
            guard selectedKeys.isEmpty || selectedKeys.contains(providerKey) else { continue }
            guard out.allSatisfy({ $0.providerKey != providerKey }) else { continue }
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let material = projectKeyMaterial(fromValue: object),
                  let loginToken = accessTokens[location.family], !loginToken.isEmpty,
                  let quotaURL = projectQuotaURL(origin: location.origin)
            else { continue }
            out.append(ZcodePlanAuth(
                providerKey: providerKey,
                kind: .codingPlan,
                apiKey: "",  // 运行时换取 project token 后填充
                quotaURL: quotaURL,
                projectLocation: location,
                projectMaterial: material,
                loginToken: loginToken
            ))
        }
        return out.sorted { $0.providerKey < $1.providerKey }
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

    // MARK: 设备标识（billing 端点强制要求 X-Device-Mid）

    /// 从本地文件对象提取设备标识：`onboarding-record.json` / `telemetry-state.json`
    /// 的 `deviceMid`。缺失或非 UUID 形态 → nil（由调用方兜底生成）。
    ///
    /// 服务端对 `billing/balance` 校验该头：缺失返回 HTTP 400 `code=3001`。
    static func deviceMid(fromOnboardingRecord record: [String: Any]?,
                          telemetryState: [String: Any]?) -> String? {
        for object in [record, telemetryState] {
            guard let raw = object?["deviceMid"] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: value) != nil { return value }
        }
        return nil
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

    /// zcode home 目录（测试可覆盖）。
    private var homeURL: URL {
        homeOverride ?? ZcodeUsageCollector.defaultDatabaseURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        let home = homeURL

        // 1. 凭据（start-plan JWT；解密失败仅表示该路径不可用，coding-plan 不依赖）。
        let credentialsURL = home.appendingPathComponent("v2/credentials.json")
        let credentials = loadCredentials(at: credentialsURL)
        let setting = readJSONObject(home.appendingPathComponent("v2/setting.json"))

        // 2. 选中套餐：新布局（connectionSelections）优先，旧布局（selectedKeys）兼容。
        let connectionKeys = ZcodeLimitsParsing.connectionSelectedKeys(fromSetting: setting)
        let legacyKeys = ZcodeLimitsParsing.selectedPlanProviderKeys(fromSetting: setting)
        let selectedKeys = connectionKeys.isEmpty ? legacyKeys : connectionKeys

        // 3. 当前布局的 coding-plan 候选（project key 链路），优先于旧 config.json 路径。
        let projectCandidates = ZcodeLimitsParsing.projectKeyCandidates(
            entries: projectKeyEntries(at: credentialsURL),
            selectedKeys: selectedKeys,
            accessTokens: oauthAccessTokens(at: credentialsURL)
        )

        // 4. 旧布局候选（config.json 明文 key + 凭据 JWT）。
        var candidates = projectCandidates + ZcodeLimitsParsing.authCandidates(
            config: readJSONObject(home.appendingPathComponent("v2/config.json")),
            availability: ZcodeLimitsParsing.planProviderAvailability(
                fromCache: readJSONObject(home.appendingPathComponent("v2/coding-plan-cache.json"))
            ),
            selectedKeys: selectedKeys,
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

        // 5. 逐候选取数；成功但无窗口（如 billing 端点对 coding 套餐返回空桶）
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
            // project key 候选需先换 project token；旧布局直接用 config 明文 key。
            let authValue: String
            if let location = candidate.projectLocation,
               let material = candidate.projectMaterial,
               let loginToken = candidate.loginToken {
                authValue = try await projectAccessToken(
                    location: location,
                    material: material,
                    loginToken: loginToken
                )
            } else {
                authValue = candidate.apiKey
            }
            var request = URLRequest(url: quotaURL)
            request.timeoutInterval = timeout
            // quota 端点鉴权：authorization 头直接放 key，无 Bearer 前缀。
            request.setValue(authValue, forHTTPHeaderField: "Authorization")
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
        // 服务端强制设备标识：缺失 → HTTP 400 code=3001（会误映射成网络错误）。
        request.setValue(resolvedDeviceMid(), forHTTPHeaderField: "X-Device-Mid")
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

    // MARK: 设备标识解析

    /// 设备标识缓存：同一进程内多次取数复用，避免每轮重读文件。
    private var cachedDeviceMid: String?

    /// 解析 `X-Device-Mid`：优先本地 `deviceMid`（onboarding / telemetry），
    /// 缺失时生成 UUID 并回写 telemetry-state.json，与 ZCode 客户端行为一致。
    private func resolvedDeviceMid() -> String {
        if let cachedDeviceMid { return cachedDeviceMid }
        let home = homeURL
        let recordURL = home.appendingPathComponent("v2/onboarding-record.json")
        let telemetryURL = home.appendingPathComponent("v2/telemetry-state.json")
        let resolved = ZcodeLimitsParsing.deviceMid(
            fromOnboardingRecord: readJSONObject(recordURL),
            telemetryState: readJSONObject(telemetryURL)
        ) ?? Self.persistedDeviceMid(at: telemetryURL, existing: readJSONObject(telemetryURL))
        cachedDeviceMid = resolved
        return resolved
    }

    /// 生成并回写 deviceMid（文件不存在时新建，保留已有字段）；写入失败仅影响
    /// 下次进程启动能否复用，本轮请求仍用内存值。
    private static func persistedDeviceMid(at telemetryURL: URL, existing: [String: Any]?) -> String {
        let generated = UUID().uuidString.lowercased()
        var object = existing ?? [:]
        object["deviceMid"] = generated
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: telemetryURL, options: .atomic)
        }
        return generated
    }

    // MARK: project token 换取

    /// project token 缓存项：token 与过期时刻。
    private struct CachedProjectToken {
        var token: String
        var expiresAt: Date
    }

    /// project token 缓存：`family + apiKeyId` → token。token 有效期约 37 分钟，
    /// 缓存避免每轮取数都签发；提前 60 秒失效。
    private var projectTokenCache: [String: CachedProjectToken] = [:]

    /// 换取 project token（带缓存）。
    private func projectAccessToken(
        location: ZcodeProjectKeyLocation,
        material: ZcodeProjectKeyMaterial,
        loginToken: String
    ) async throws -> String {
        let cacheKey = "\(location.family):\(material.apiKeyId)"
        if let cached = projectTokenCache[cacheKey], cached.expiresAt > Date() {
            return cached.token
        }
        guard let url = ZcodeLimitsParsing.projectAccessTokenURL(
            location: location,
            material: material
        ) else {
            throw LimitError.decoding("ZCode project access token URL invalid")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(loginToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "clientType": "zcode",
            "clientVersion": Self.appVersion,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let payload = try await jsonBody(for: request, label: "project token")
        let data = payload["data"] as? [String: Any] ?? [:]
        guard let token = (data["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw LimitError.decoding("ZCode project token missing accessToken")
        }
        let expiresIn = (data["expiresIn"] as? NSNumber)?.doubleValue
        // 提前 60 秒失效；服务端未给时长时按 15 分钟保守估计。
        let lifetime = max((expiresIn ?? 900) - 60, 60)
        projectTokenCache[cacheKey] = CachedProjectToken(
            token: token,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        return token
    }

    /// 签发请求声明的客户端版本：取 ZCode 应用版本，缺失时回落固定值。
    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "3.16.3"
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

    /// `credentials.json` 中所有 project key 条目：键名 → 解密后的明文 JSON。
    /// 解密失败的条目直接跳过（fail-soft）。
    private func projectKeyEntries(at credentialsURL: URL) -> [(key: String, value: String)] {
        guard let parsed = readJSONObject(credentialsURL) else { return [] }
        return parsed.compactMap { key, rawValue in
            guard key.hasPrefix(ZcodeLimitsParsing.projectKeyLocationPrefix),
                  let value = decrypted(rawValue)
            else { return nil }
            return (key: key, value: value)
        }
    }

    /// `credentials.json` 中按域索引的 OAuth access token（`oauth:{family}:access_token`）。
    private func oauthAccessTokens(at credentialsURL: URL) -> [String: String] {
        guard let parsed = readJSONObject(credentialsURL) else { return [:] }
        var out: [String: String] = [:]
        for family in ["bigmodel", "zai"] {
            let key = "oauth:\(family):access_token"
            if let token = decrypted(parsed[key])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                out[family] = token
            }
        }
        return out
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
