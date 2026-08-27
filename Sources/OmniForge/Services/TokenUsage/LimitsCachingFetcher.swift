import Foundation

/// 限额取数缓存装饰器 — 在原始取数器外加「内存 TTL / 磁盘 last-good / 429 冷却持久化」（参考 06）。
///
/// 语义（#03 决策）：
/// - `force`（手动刷新）穿透内存新鲜缓存，但**不能**穿透 429 冷却；
/// - 网络/解码失败回退 last-good 快照并标 `stale`（保留 `capturedAt`）；
/// - 429 结果写冷却文件，冷却期跳过上游并回退 last-good；
/// - `reauthRequired` 短路回抛：不回退、不覆盖缓存。
final class LimitsCachingFetcher: LimitsFetching {
    let provider: TokenUsageProvider
    private let inner: LimitsFetching
    private let cache: LimitsCaching
    private let now: () -> Date

    init(
        inner: LimitsFetching,
        cache: LimitsCaching,
        now: @escaping () -> Date = { Date() }
    ) {
        self.provider = inner.provider
        self.inner = inner
        self.cache = cache
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // ① 429 冷却持久化：冷却期跳过上游（force 也不能穿透）。
        if let retryAt = cache.cooldown(for: provider), retryAt > now() {
            return fallback(issue: .rateLimited(retryAt: retryAt), now: now())
        }
        // ② 内存新鲜命中（force 穿透）。
        if !force,
           let fresh = cache.memorySnapshot(for: provider),
           fresh.configured, fresh.issue == nil, !fresh.stale {
            return fresh
        }
        // ③ 上游取数。
        do {
            if let limits = try await inner.fetchLimits(force: force) {
                // 带 issue 的快照不是成功结果（如 Antigravity「已安装但进程不在」返回错误态快照）：
                // 不得 storeSuccess 覆盖 last-good，改走失败回退（last-good 标 stale 展示）。
                guard limits.issue == nil else {
                    return fallback(issue: limits.issue!, now: now())
                }
                cache.storeSuccess(limits)
                return limits
            }
            cache.storeNotConfigured(provider)
            return nil
        } catch let error as LimitError {
            switch error {
            case .reauthRequired:
                throw error
            case .rateLimited(let retryAt):
                cache.storeRateLimit(for: provider, retryAt: retryAt)
                return fallback(issue: .rateLimited(retryAt: retryAt), now: now())
            case .network, .decoding, .notRunning:
                return fallback(issue: error, now: now())
            }
        } catch {
            return fallback(issue: .network(String(describing: error)), now: now())
        }
    }

    /// 失败回退：优先 last-good 快照（标 stale、保留 capturedAt），否则空窗口错误态。
    private func fallback(issue: LimitError, now: Date) -> ProviderUsageLimits {
        if let lastGood = cache.lastGoodSnapshot(for: provider) {
            var copy = lastGood
            copy.stale = true
            copy.issue = issue
            return copy
        }
        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: [:],
            confidence: .official,
            capturedAt: now,
            stale: true,
            issue: issue
        )
    }
}
