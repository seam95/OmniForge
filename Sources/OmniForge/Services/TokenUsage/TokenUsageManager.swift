import Combine
import Foundation

/// Token 用量运行时 — 调度限额取数 / 用量采集 / 告警，聚合为面板快照。
///
/// #02：限额侧接入（多 provider 并行、单家失败不拖垮整体、单飞合并）；
/// 用量采集（#04+）与告警（#11）按 issue 逐步接入。
@MainActor
final class TokenUsageManager: ObservableObject {
    @Published private(set) var isActive = false
    /// 各 provider 最新限额快照（含未配置/错误态条目）。
    @Published private(set) var limits: [TokenUsageProvider: ProviderUsageLimits] = [:]
    /// 最近一次任何成功取数时间（来源标注「X 分钟前更新」）。
    @Published private(set) var limitUpdateAt: Date?

    private let preferences: TokenUsagePreferences
    private let fetchers: [TokenUsageProvider: LimitsFetching]
    private let scheduler: RepeatingScheduling
    private var refreshTimer: AnyCancellable?
    /// 单飞合并：并发未命中共享同一次上游拉取，避免打爆 Claude OAuth 端点。
    private var inFlight = Set<TokenUsageProvider>()
    private var cancellables = Set<AnyCancellable>()

    init(
        preferences: TokenUsagePreferences,
        fetchers: [TokenUsageProvider: LimitsFetching] = [:],
        scheduler: RepeatingScheduling = TimerRepeatingScheduler()
    ) {
        self.preferences = preferences
        self.fetchers = fetchers
        self.scheduler = scheduler

        preferences.$configuration
            .map(\.limitRefreshMinutes)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.rescheduleRefreshTimer()
            }
            .store(in: &cancellables)
    }

    /// 已配置凭证的 provider（按目录顺序）。
    var configuredProviders: [TokenUsageProvider] {
        let configured = Set(limits.filter { $0.value.configured }.map(\.key))
        return TokenUsageProvider.allCases.filter { configured.contains($0) }
    }

    /// 有任何 provider 配置了凭证（限额区块显隐判断）。
    var hasAnyConfiguredProvider: Bool {
        limits.values.contains { $0.configured }
    }

    /// 启用：开始限额取数与用量采集（由 FeatureRuntime binding 驱动）。
    func start() {
        guard !isActive else { return }
        isActive = true
        refreshLimits(force: false)
        rescheduleRefreshTimer()
    }

    /// 停用：停止所有后台刷新与监听。
    func stop() {
        guard isActive else { return }
        isActive = false
        refreshTimer?.cancel()
        refreshTimer = nil
        inFlight.removeAll()
    }

    /// 手动刷新入口（底栏「刷新」）：force 穿透内存/磁盘新鲜缓存，但 429 冷却不可穿透（#03）。
    func refreshNow(force: Bool = false) {
        guard isActive else { return }
        refreshLimits(force: force)
    }

    // MARK: - 限额取数

    private func refreshLimits(force: Bool) {
        for (provider, fetcher) in fetchers where !inFlight.contains(provider) {
            inFlight.insert(provider)
            Task { [weak self] in
                guard let self else { return }
                let result = await self.fetchOne(provider: provider, fetcher: fetcher, force: force)
                self.apply(result, provider: provider)
                self.inFlight.remove(provider)
            }
        }
    }

    private func fetchOne(
        provider: TokenUsageProvider,
        fetcher: LimitsFetching,
        force: Bool
    ) async -> ProviderUsageLimits {
        do {
            if let limits = try await fetcher.fetchLimits(force: force) {
                return limits
            }
            return .notConfigured(provider)
        } catch let error as LimitError {
            return ProviderUsageLimits(
                provider: provider,
                configured: true,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: [:],
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: error
            )
        } catch {
            return ProviderUsageLimits(
                provider: provider,
                configured: true,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: [:],
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: .network(String(describing: error))
            )
        }
    }

    /// 记录快照并维护「更新时间」语义（#03）：取最近一次**有数据/回退**快照的 `capturedAt`；
    /// 纯错误态（无窗口、非 stale 回退）不推进时间，错误时来源标注对齐缓存。
    private func apply(_ result: ProviderUsageLimits, provider: TokenUsageProvider) {
        limits[provider] = result
        // 仅当有实际数据（新鲜成功或 last-good 回退）时推进「更新时间」，且取两者较新者。
        guard result.configured, result.issue == nil || !result.windows.isEmpty else { return }
        let captured = result.capturedAt
        if limitUpdateAt == nil || limitUpdateAt! < captured {
            limitUpdateAt = captured
        }
    }

    private func rescheduleRefreshTimer() {
        refreshTimer?.cancel()
        refreshTimer = nil
        guard isActive else { return }
        let interval = TimeInterval(preferences.configuration.limitRefreshMinutes * 60)
        refreshTimer = scheduler.schedule(every: interval) { [weak self] in
            self?.refreshLimits(force: false)
        }
    }
}
