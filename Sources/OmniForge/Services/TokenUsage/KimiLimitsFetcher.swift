import Foundation

// MARK: - coding/v1/usages 响应解码

/// Kimi usages 响应解码 — 纯函数，独立可测（参考 normalizeKimiUsageResponse）。
///
/// 槽位映射：`usage`（主额度）→ session、`limits[0].detail ?? limits[0]` → weekly、
/// `totalQuota`（订阅总额度）→ monthly（参考 03 槽位约定）。
/// 窗口废弃规则（参考 kimiWindowFromUsage）：limit 必须 > 0；used 缺时用 `limit - remaining`
/// 反推；两者都不可得 → 丢弃（绝不显示 0%）。
enum KimiUsageResponseDecoder {
    static func decodeFromBody(_ object: [String: Any]) -> [LimitWindowKind: UsageWindow] {
        let firstLimit = (object["limits"] as? [[String: Any]])?.first
        let detail: [String: Any]? = {
            if let raw = firstLimit {
                return (raw["detail"] as? [String: Any]) ?? raw
            }
            return nil
        }()
        var windows: [LimitWindowKind: UsageWindow] = [:]
        if let window = windowFromUsage(object["usage"]) {
            windows[.session] = window
        }
        if let window = windowFromUsage(detail) {
            windows[.weekly] = window
        }
        if let window = windowFromUsage(object["totalQuota"]) {
            windows[.monthly] = window
        }
        return windows
    }

    /// 单窗口 decode（便于 fetcher 层组合 / 测试）。
    static func decode(_ value: Any?, usage: [String: Any]) -> [LimitWindowKind: UsageWindow] {
        decodeFromBody(["usage": usage])
    }

    /// usage/detail/totalQuota 的单窗解码：limit > 0 才有效。
    static func windowFromUsage(_ data: Any?) -> UsageWindow? {
        guard let data = data as? [String: Any] else { return nil }
        let limit = UsageWindowParsing.numeric(data["limit"])
        guard let limit, limit > 0 else { return nil }
        var used = UsageWindowParsing.numeric(data["used"])
        if used == nil, let remaining = UsageWindowParsing.numeric(data["remaining"]) {
            used = limit - remaining
        }
        guard let used else { return nil }
        let usedPercent = UsageWindowParsing.clampPercent(used / limit * 100) ?? 0
        return UsageWindow(
            usedPercent: usedPercent,
            resetAt: UsageWindowParsing.parseResetDate(
                data["resetTime"] ?? data["reset_at"] ?? data["resetAt"]
            ),
            limit: limit,
            used: used,
            remaining: UsageWindowParsing.numeric(data["remaining"]),
            unit: nil,
            windowSeconds: nil
        )
    }
}

// MARK: - 取数器

/// Kimi 限额取数器：kimi-code.json → 临期自刷新 → `GET coding/v1/usages`（参考 08/fetchKimiLimits）。
///
/// 刷新语义：`expires_at` 30 秒容差（对齐 TokenTracker）；401/403 → `reauthRequired`；
/// 网络/HTTP 类刷新失败回退旧 token 继续（best-effort）。
final class KimiLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .kimi

    /// 官方 usages 端点（集中定义，可改）。
    static let usageEndpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!

    private let credentials: KimiCredentialReading
    private let refresher: KimiTokenRefreshing
    private let persistence: (KimiAuthBundle, KimiRefreshedTokens, Date) throws -> KimiAuthBundle
    private let client: ProviderAPIClient
    private let now: () -> Date

    init(
        credentials: KimiCredentialReading = KimiAuthFileCredentialReader(),
        refresher: KimiTokenRefreshing = KimiTokenRefresher(),
        persistence: @escaping (KimiAuthBundle, KimiRefreshedTokens, Date) throws -> KimiAuthBundle = KimiAuthPersistence.persistDefault,
        client: ProviderAPIClient = ProviderAPIClient(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.refresher = refresher
        self.persistence = persistence
        self.client = client
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 未配置（kimi-code.json 缺失/不可读）→ nil，由管理器归一化为 notConfigured。
        guard let bundle = try? credentials.readBundle() else {
            return nil
        }
        let current = try await ensureFresh(bundle)

        let object: [String: Any]
        do {
            object = try await client.getJSON(
                url: Self.usageEndpoint,
                headers: [
                    "Authorization": "Bearer \(current.accessToken)",
                    "Accept": "application/json",
                ]
            )
        } catch LimitError.decoding {
            // 解析失败降级不崩：返回配置态空窗口（卡片仅显示错误行/无从显示），单家失败不拖累
            return providerLimits(windows: [:])
        }
        return providerLimits(windows: KimiUsageResponseDecoder.decodeFromBody(object))
    }

    private func providerLimits(windows: [LimitWindowKind: UsageWindow]) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: .kimi,
            configured: true,
            subscriptionStatus: .active,
            planLabel: nil, // 参考：#130 subType 是额度来源而非套餐，显示裸品牌
            windows: windows,
            confidence: .official,
            capturedAt: now(),
            stale: false,
            issue: nil
        )
    }

    // MARK: 内部

    /// 「临期才刷」：expires_at 30 秒容差内才通知刷新；401/403 刷新失败 → `reauthRequired`
    /// 短路；网络/HTTP 类失败回退旧 token 继续（best-effort，与 Codex 一致）。
    private func ensureFresh(_ bundle: KimiAuthBundle) async throws -> KimiAuthBundle {
        guard KimiTokenFreshness.isStale(expiresAt: bundle.expiresAt, now: now()) else {
            return bundle
        }
        guard let refreshToken = bundle.refreshToken, !refreshToken.isEmpty else {
            return bundle
        }
        do {
            let tokens = try await refresher.refresh(refreshToken: refreshToken)
            return try persistence(bundle, tokens, now())
        } catch let error as KimiTokenRefreshError {
            switch error {
            case .noRefreshToken, .refreshRejected:
                throw LimitError.reauthRequired
            case .httpError, .invalidResponse, .network:
                return bundle // 网络/副作用失败：回退旧 token 继续
            }
        } catch {
            return bundle
        }
    }
}
