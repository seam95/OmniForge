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
        refreshLimits()
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

    /// 手动刷新入口（底栏「刷新」；#03 起穿透缓存但仍遵循 429 冷却）。
    func refreshNow(force: Bool = false) {
        guard isActive else { return }
        refreshLimits()
    }

    // MARK: - 限额取数

    private func refreshLimits() {
        for (provider, fetcher) in fetchers where !inFlight.contains(provider) {
            inFlight.insert(provider)
            Task { [weak self] in
                guard let self else { return }
                let result = await self.fetchOne(fetcher)
                self.limits[provider] = result
                if result.configured {
                    self.limitUpdateAt = Date()
                }
                self.inFlight.remove(provider)
            }
        }
    }

    private func fetchOne(_ fetcher: LimitsFetching) async -> ProviderUsageLimits {
        do {
            if let limits = try await fetcher.fetchLimits() {
                return limits
            }
            return .notConfigured(fetcher.provider)
        } catch let error as LimitError {
            return ProviderUsageLimits(
                provider: fetcher.provider,
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
                provider: fetcher.provider,
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

    private func rescheduleRefreshTimer() {
        refreshTimer?.cancel()
        refreshTimer = nil
        guard isActive else { return }
        let interval = TimeInterval(preferences.configuration.limitRefreshMinutes * 60)
        refreshTimer = scheduler.schedule(every: interval) { [weak self] in
            self?.refreshLimits()
        }
    }
}
