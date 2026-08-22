import Foundation

// MARK: - wham 响应解码（防御式：端点字段变动 → 降级不崩）

/// wham reset-credits 精简解析（参考 normalizeCodexResetCredits）。
struct CodexResetCredits: Equatable {
    var availableCount: Int?
    var totalEarnedCount: Int?
    /// 可用 credits 中最早的 expires_at（用于补齐 credits 窗口的 reset）。
    var earliestExpiresAt: Date?
}

/// Codex wham/usage 响应解码 — 纯函数，独立可测（参考 03/08 + usage-limits.js:283-432）。
///
/// 窗口映射：`rate_limit.primary_window/secondary_window` 按 `limit_window_seconds`
/// 分类（18000=会话 / 604800=周；参考 03 关键技巧），分类失败回退按位置命名；
/// `spend_control.individual_limit` → 额度型 credits 窗口；主窗口缺失时补
/// `additional_rate_limits`（spark）。任何窗口缺「可用百分比」则丢弃（不渲染为 0%）。
enum CodexWhamResponseDecoder {
    static let sessionWindowSeconds: Double = 18000
    static let weeklyWindowSeconds: Double = 604800

    /// ISO 解析：优先带小数秒（wham 的 `expires_at` 形如 `2027-08-22T10:00:00.000Z`），
    /// 失败回退无小数秒格式。
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    static func decode(_ object: [String: Any]) -> [LimitWindowKind: UsageWindow] {
        var windows: [LimitWindowKind: UsageWindow] = [:]

        // ① 主 rate_limit 窗口：按秒数分类（优先于槽位位置）。
        let rateLimit = object["rate_limit"] as? [String: Any] ?? [:]
        let primary = rateLimit["primary_window"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any]
        var session: UsageWindow?
        var weekly: UsageWindow?
        for raw in [primary, secondary].compactMap({ $0 }) {
            guard let classified = classify(raw) else { continue }
            if classified.kind == .session, session == nil { session = classified.window }
            if classified.kind == .weekly, weekly == nil { weekly = classified.window }
        }
        // ② 两者都分类失败 → 位置兜底（保留意外窗口数据，不静默丢弃）。
        if session == nil, weekly == nil {
            if let primary { session = usableWindow(primary) }
            if let secondary { weekly = usableWindow(secondary) }
        }
        // ③ spark 补充：主窗口缺失时用 additional_rate_limits 同类分类补齐。
        if session == nil || weekly == nil {
            fillSparkWindows(
                object["additional_rate_limits"],
                session: &session,
                weekly: &weekly
            )
        }
        if let session { windows[.session] = session }
        if let weekly { windows[.weekly] = weekly }

        // ④ 额度型窗口：spend_control.individual_limit。
        if let spend = object["spend_control"] as? [String: Any],
           let individual = spend["individual_limit"] as? [String: Any],
           let credits = creditWindow(individual) {
            windows[.credits] = credits
        }
        return windows
    }

    /// reset-credits 解码（`rate_limit_reset_credits` 或兄弟端点响应，形状一致）。
    static func decodeResetCredits(_ value: Any?, now: Date = Date()) -> CodexResetCredits? {
        guard let object = value as? [String: Any] else { return nil }
        let available = nonNegativeInt(object["available_count"])
        let totalEarned = nonNegativeInt(object["total_earned_count"])
        let credits = (object["credits"] as? [[String: Any]]) ?? []
        let earliest = credits
            .compactMap { resetCredit($0, now: now) }
            .map { $0 }
            .sorted { $0 < $1 }
            .first
        if available == nil, totalEarned == nil, earliest == nil { return nil }
        return CodexResetCredits(
            availableCount: available,
            totalEarnedCount: totalEarned,
            earliestExpiresAt: earliest
        )
    }

    // MARK: 内部

    /// 按秒数分类窗口；无秒数 → nil（调用方再走位置兜底）。
    private static func classify(_ raw: [String: Any]) -> (kind: LimitWindowKind, window: UsageWindow)? {
        guard let seconds = numeric(raw["limit_window_seconds"]) else { return nil }
        guard let window = usableWindow(raw) else { return nil }
        switch seconds {
        case sessionWindowSeconds: return (.session, window)
        case weeklyWindowSeconds: return (.weekly, window)
        default: return nil
        }
    }

    /// 窗口可用性：有 used_percent 或 limit/used 可反推百分比才保留（否则丢弃，绝不显示 0%）。
    private static func usableWindow(_ raw: [String: Any]) -> UsageWindow? {
        let hasPercent = numeric(raw["used_percent"]) != nil
        let hasRatio = (numeric(raw["limit"]) ?? 0) > 0 && numeric(raw["used"]) != nil
        guard hasPercent || hasRatio else { return nil }
        return UsageWindowParsing.makeWindow(from: raw)
    }

    /// spark 窗口补充：`limit_name`/`metered_feature` 含 "spark" 的条目。
    private static func fillSparkWindows(
        _ value: Any?,
        session: inout UsageWindow?,
        weekly: inout UsageWindow?
    ) {
        guard let entries = value as? [[String: Any]] else { return }
        for entry in entries {
            let name = (entry["limit_name"] as? String ?? "").lowercased()
            let feature = (entry["metered_feature"] as? String ?? "").lowercased()
            guard name.contains("spark") || feature.contains("spark") else { continue }
            guard let rateLimit = entry["rate_limit"] as? [String: Any] else { continue }
            let primary = rateLimit["primary_window"] as? [String: Any]
            let secondary = rateLimit["secondary_window"] as? [String: Any]
            for raw in [primary, secondary].compactMap({ $0 }) {
                guard let classified = classify(raw) else { continue }
                if classified.kind == .session, session == nil { session = classified.window }
                if classified.kind == .weekly, weekly == nil { weekly = classified.window }
            }
            if session == nil, weekly == nil {
                if let primary { session = usableWindow(primary) }
                if session == nil, let secondary { weekly = usableWindow(secondary) }
            }
            if session != nil, weekly != nil { break }
        }
    }

    /// 额度型窗口：limit/used/remaining/used_percent/reset_at → UsageWindow（unit 固定 credits）。
    private static func creditWindow(_ raw: [String: Any]) -> UsageWindow? {
        let hasFields = ["limit", "used", "remaining", "used_percent", "reset_at"]
            .contains { numeric(raw[$0]) != nil }
        guard hasFields else { return nil }
        let window = UsageWindowParsing.makeWindow(from: raw)
        return UsageWindow(
            usedPercent: window.usedPercent,
            resetAt: window.resetAt,
            limit: window.limit,
            used: window.used,
            remaining: window.remaining,
            unit: "credits",
            windowSeconds: window.windowSeconds
        )
    }

    /// 单条 reset credit：仅 available、reset_type 为 codex_rate_limits（或缺失）、未过期 → expires_at。
    private static func resetCredit(_ row: [String: Any], now: Date) -> Date? {
        guard (row["status"] as? String) == "available" else { return nil }
        if let resetType = row["reset_type"] as? String, resetType != "codex_rate_limits" {
            return nil
        }
        guard let expires = row["expires_at"] as? String,
              let date = isoFractional.date(from: expires) ?? isoPlain.date(from: expires) else {
            return nil
        }
        guard date > now else { return nil }
        return date
    }

    private static func numeric(_ value: Any?) -> Double? {
        UsageWindowParsing.numeric(value)
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let number = UsageWindowParsing.numeric(value), number >= 0, number.rounded() == number else {
            return nil
        }
        return Int(number)
    }
}

// MARK: - 取数器

/// Codex 限额取数器：`auth.json` → 临期自刷新 → `wham/usage` + 兄弟端点（参考 08）。
///
/// 请求序：① wham/usage（主计数）→ ② wham/rate-limit-reset-credits（补 reset，
/// 短超时 + 失败降级）；401/403/429 语义与 Claude 一致（复用 ProviderAPIClient）。
/// 刷新失败细分：401 类（expired/reused/invalidated）→ `reauthRequired`（prompt codex login），
/// 网络类失败回退旧 token 继续（best-effort，与 TokenTracker 一致）。
final class CodexLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .codex

    static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    /// 兄弟端点短超时（正主端点是计数主源，兄弟只补 reset — 参考 codexResetCreditListTimeoutMs）。
    static let resetCreditsTimeout: TimeInterval = 3

    private let credentials: CodexCredentialReading
    private let refresher: CodexTokenRefreshing
    private let persistence: (CodexAuthBundle, CodexRefreshedTokens, Date) throws -> CodexAuthBundle
    private let client: ProviderAPIClient
    private let resetCreditsClient: ProviderAPIClient
    private let now: () -> Date

    init(
        credentials: CodexCredentialReading = CodexAuthFileCredentialReader(),
        refresher: CodexTokenRefreshing = CodexTokenRefresher(),
        persistence: @escaping (CodexAuthBundle, CodexRefreshedTokens, Date) throws -> CodexAuthBundle = CodexAuthPersistence.persistDefault,
        client: ProviderAPIClient = ProviderAPIClient(),
        resetCreditsClient: ProviderAPIClient = ProviderAPIClient(timeout: CodexLimitsFetcher.resetCreditsTimeout),
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.refresher = refresher
        self.persistence = persistence
        self.client = client
        self.resetCreditsClient = resetCreditsClient
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 未配置（auth.json 缺失/不可读）→ nil，由管理器归一化为 notConfigured。
        guard let bundle = try? credentials.readBundle() else {
            return nil
        }
        let current = try await ensureFresh(bundle)
        let headers = authHeaders(for: current)

        let object = try await client.getJSON(url: Self.usageEndpoint, headers: headers)
        var windows = CodexWhamResponseDecoder.decode(object)

        // 兄弟端点：重置额度的只读来源；失败降级用主端点体内的 rate_limit_reset_credits。
        var resetCredits = CodexWhamResponseDecoder.decodeResetCredits(
            object["rate_limit_reset_credits"],
            now: now()
        )
        do {
            let sibling = try await resetCreditsClient.getJSON(
                url: Self.resetCreditsEndpoint,
                headers: headers
            )
            if let better = CodexWhamResponseDecoder.decodeResetCredits(sibling, now: now()) {
                resetCredits = better
            }
        } catch {
            // 兄弟端点失败不崩：reset 信息保留主端点体内值。
        }

        // credits 窗口缺 reset_at 时，用该窗口的补充 reset 信息兜底（无则保持原样）。
        if var credits = windows[.credits], credits.resetAt == nil, let resetCredits {
            var enriched = credits
            enriched.resetAt = resetCredits.earliestExpiresAt
            windows[.credits] = enriched
        }

        let planLabel = CodexPlanExtractor.displayablePlan(
            accessToken: current.accessToken,
            idToken: current.idToken
        )
        return ProviderUsageLimits(
            provider: .codex,
            configured: true,
            subscriptionStatus: planLabel != nil ? .active : .unknown,
            planLabel: planLabel,
            windows: windows,
            confidence: .official,
            capturedAt: now(),
            stale: false,
            issue: nil
        )
    }

    // MARK: 内部

    /// 「临期才刷」：refresh token 缺失或非 401 刷新失败 → 继续用现有 token（best-effort）；
    /// 401 类刷新失败 → `reauthRequired` 短路（提示 codex login）。
    private func ensureFresh(_ bundle: CodexAuthBundle) async throws -> CodexAuthBundle {
        guard CodexTokenFreshness.isStale(
            accessToken: bundle.accessToken,
            lastRefresh: bundle.lastRefresh,
            now: now()
        ) else {
            return bundle
        }
        let refreshToken = bundle.refreshToken ?? ""
        guard !refreshToken.isEmpty else { return bundle }
        do {
            let tokens = try await refresher.refresh(refreshToken: refreshToken)
            return try persistence(bundle, tokens, now())
        } catch let error as CodexTokenRefreshError {
            switch error {
            case .refreshTokenExpired, .refreshTokenReused, .refreshTokenInvalidated, .refreshRejected:
                throw LimitError.reauthRequired
            case .noRefreshToken, .httpError, .invalidResponse, .network:
                return bundle // 网络/副作用失败：回退旧 token 继续
            }
        } catch {
            return bundle
        }
    }

    private func authHeaders(for bundle: CodexAuthBundle) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer \(bundle.accessToken)",
            "Accept": "application/json",
        ]
        if let accountID = bundle.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }
}
