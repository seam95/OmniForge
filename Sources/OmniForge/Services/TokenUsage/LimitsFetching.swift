import Foundation

/// 限额取数协议 — 每 provider 一个实现；策略链（API → 网页 → 本地估算）在实现内部。
protocol LimitsFetching: AnyObject {
    var provider: TokenUsageProvider { get }

    /// 返回 nil 表示「未配置凭证」（调用方降级 `ProviderUsageLimits.notConfigured`）；
    /// 其余失败抛 `LimitError`（auth 错误须短路，不回退）。
    /// - Parameter force: 穿透内存新鲜缓存（手动刷新语义）；实现可忽略。
    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits?
}

extension LimitsFetching {
    /// 兼容入口：非强制刷新。
    func fetchLimits() async throws -> ProviderUsageLimits? {
        try await fetchLimits(force: false)
    }
}
