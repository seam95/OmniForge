import Combine
import Foundation

/// Token 用量运行时 — 调度限额取数 / 用量采集 / 告警，聚合为面板快照。
///
/// #02：限额侧接入（多 provider 并行、单家失败不拖垮整体、单飞合并）；
/// #04：用量侧接入（采集器启停 + 后台回填 + 今日用量快照发布）；
/// 告警（#11）按 issue 逐步接入。
@MainActor
final class TokenUsageManager: ObservableObject {
    @Published private(set) var isActive = false
    /// 各 provider 最新限额快照（含未配置/错误态条目）。
    @Published private(set) var limits: [TokenUsageProvider: ProviderUsageLimits] = [:]
    /// 最近一次任何成功取数时间（来源标注「X 分钟前更新」）。
    @Published private(set) var limitUpdateAt: Date?

    // MARK: #04 — 用量侧
    /// 聚合用量快照（全部已配置 provider；nil = 窗口内无任何数据）。
    @Published private(set) var usageOverview: TokenUsageOverview?
    /// 回填中（首次启用后台全量回填；回填中 UI 显示「正在统计历史用量…」）。
    @Published private(set) var usageBackfilling = false
    /// 窗口内有用量数据的 provider（按目录序）。
    @Published private(set) var usageProvidersWithData: [TokenUsageProvider] = []

    /// 用量区块显隐（SPEC 4.3）：有数据或回填中才显示。
    var showingUsageBlock: Bool {
        usageOverview != nil || usageBackfilling
    }

    private let preferences: TokenUsagePreferences
    private let fetchers: [TokenUsageProvider: LimitsFetching]
    private let scheduler: RepeatingScheduling
    private let usageStore: UsageStoring?
    private let usageCollectors: [TokenUsageProvider: UsageCollecting]
    /// #11：告警触发器 — 随限额刷新同频评估（阈值/步速）。
    private let alerts: TokenUsageAlertManager?
    private var refreshTimer: AnyCancellable?
    /// 单飞合并：并发未命中共享同一次上游拉取，避免打爆 Claude OAuth 端点。
    private var inFlight = Set<TokenUsageProvider>()
    private var cancellables = Set<AnyCancellable>()

    init(
        preferences: TokenUsagePreferences,
        fetchers: [TokenUsageProvider: LimitsFetching] = [:],
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        usageStore: UsageStoring? = nil,
        usageCollectors: [TokenUsageProvider: UsageCollecting] = [:],
        alerts: TokenUsageAlertManager? = nil
    ) {
        self.preferences = preferences
        self.fetchers = fetchers
        self.scheduler = scheduler
        self.usageStore = usageStore
        self.usageCollectors = usageCollectors
        self.alerts = alerts

        for (provider, collector) in usageCollectors {
            collector.onUsageDidChange = { [weak self] changed in
                guard let self else { return }
                self.usageDidChange(changed)
            }
            collector.onBackfillStateChange = { [weak self] value in
                self?.usageBackfilling = value
            }
        }

        preferences.$configuration
            .map(\.limitRefreshMinutes)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.rescheduleRefreshTimer()
            }
            .store(in: &cancellables)
    }

    /// 已配置凭证的 provider（按用户偏好顺序）。
    var configuredProviders: [TokenUsageProvider] {
        let configured = Set(limits.filter { $0.value.configured }.map(\.key))
        return preferences.configuration.providerOrder.filter { configured.contains($0) }
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
        // #04：启动采集器（首次即后台全量回填），并先渲染一次已有快照。
        for collector in usageCollectors.values {
            collector.start()
        }
        refreshUsageSnapshot()
    }

    /// 停用：停止所有后台刷新与监听。
    func stop() {
        guard isActive else { return }
        isActive = false
        refreshTimer?.cancel()
        refreshTimer = nil
        inFlight.removeAll()
        usageBackfilling = false
        for collector in usageCollectors.values {
            collector.stop()
        }
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
        // #11：告警随限额刷新同频评估（内部按窗口 resetAt 防抖）。
        alerts?.evaluate(result)
        // 仅当有实际数据（新鲜成功或 last-good 回退）时推进「更新时间」，且取两者较新者。
        guard result.configured, result.issue == nil || !result.windows.isEmpty else { return }
        let captured = result.capturedAt
        if limitUpdateAt == nil || limitUpdateAt! < captured {
            limitUpdateAt = captured
        }
    }

    // MARK: - 用量侧（#04）

    /// 指定 provider 的用量快照（无窗口数据 → nil；面板切单家时使用）。
    func usageOverview(for provider: TokenUsageProvider) -> TokenUsageOverview? {
        usageOverview(filteredBy: provider, period: .today)
    }

    /// 面板用量快照：按周期（今日/本周/本月）与 provider 过滤聚合（#05 周期选择器）。
    /// `filteredBy == nil` 表示全部 provider 聚合口径；无窗口数据 → nil。
    func usageOverview(filteredBy provider: TokenUsageProvider?, period: TokenUsagePeriod) -> TokenUsageOverview? {
        guard let buckets = bucketsForPanel(filteredBy: provider, period: period) else { return nil }
        let now = Date()
        return UsageOverviewBuilder.make(buckets: buckets, now: now, calendar: .current, period: period)
    }

    /// 面板分布卡：按周期与 provider 过滤聚合（按模型 / 按 Provider 两区）。
    /// 数据驱动，不做 provider 特化：谁有数据谁出现（SPEC 4.2 / #05）。无窗口数据 → nil。
    /// #09：云端口径的 Cursor 行在「全部」口径下即使窗口内无数据也占位（`--` + 徽标）。
    func usageDistribution(filteredBy provider: TokenUsageProvider?, period: TokenUsagePeriod) -> UsageDistribution? {
        guard let buckets = bucketsForPanel(filteredBy: provider, period: period) else { return nil }
        let now = Date()
        return UsageDistributionBuilder.make(
            buckets: buckets,
            now: now,
            calendar: .current,
            period: period,
            configuredProviders: provider == nil ? configuredProviders : [],
            preferredOrder: preferences.configuration.providerOrder
        )
    }

    /// 读取所选周期窗口内的桶（provider 过滤为 nil 时聚合全部）。
    /// 今日周期额外加载近 7 日数据，保证趋势序列有值；周/月按周期窗口加载。
    private func bucketsForPanel(
        filteredBy provider: TokenUsageProvider?,
        period: TokenUsagePeriod
    ) -> [UsageBucketState]? {
        guard let usageStore else { return nil }
        let now = Date()
        let window: (start: Date, end: Date)
        switch period {
        case .today:
            window = snapshotWindow(now: now)
        case .week, .month:
            guard let periodWindow = UsagePeriodWindow.window(for: period, now: now, calendar: .current) else {
                return nil
            }
            window = periodWindow
        }
        let providers = provider.map { Set([$0]) }
        return usageStore.loadBuckets(from: window.start, to: window.end, providers: providers)
    }

    /// 采集器回调（主线程）：重新计算面板快照。
    private func usageDidChange(_ provider: TokenUsageProvider) {
        refreshUsageSnapshot()
    }

    private func refreshUsageSnapshot() {
        guard let usageStore else { return }
        let now = Date()
        let (start, end) = snapshotWindow(now: now)
        let buckets = usageStore.loadBuckets(from: start, to: end, providers: nil)
        usageOverview = UsageOverviewBuilder.make(buckets: buckets, now: now, calendar: .current)
        let withData = Set(buckets.map(\.key.provider))
        usageProvidersWithData = preferences.configuration.providerOrder.filter { withData.contains($0) }
    }

    /// 快照窗口：近 7 日（今日起往前 6 天）~ 明日 0 点。
    private func snapshotWindow(now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(
            byAdding: .day,
            value: -(UsageOverviewBuilder.trendDays - 1),
            to: todayStart
        ) ?? todayStart
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? now.addingTimeInterval(86_400)
        return (weekStart, tomorrowStart)
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
