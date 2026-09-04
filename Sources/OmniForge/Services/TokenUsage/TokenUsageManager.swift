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
    /// 菜单栏「今日 token」消费此快照（保持既有路径不变）。
    @Published private(set) var usageOverview: TokenUsageOverview?
    /// 回填中（首次启用后台全量回填；回填中 UI 显示「正在统计历史用量…」）。
    @Published private(set) var usageBackfilling = false
    /// 全历史日聚合缓存（按本地日 × provider；仪表盘汇总卡/热力图/趋势的单一数据源）。
    /// 在 `refreshUsageSnapshot()` 随用量变更全量刷新一次，避免每次渲染重复扫全历史。
    @Published private(set) var usageDailyProviderAggregates: [UsageDayProviderAggregate] = []
    /// 仪表盘展示快照（SPEC §9.2）：后台算齐全部周期，渲染只读内存，
    /// 不在 body / section 切换中访问存储。nil = 尚未完成首次构建。
    @Published private(set) var dashboardSnapshot: TokenUsageDashboardSnapshot?
    /// 已配置凭证的 provider（Keychain/环境变量判定）。进入页面只读此缓存，
    /// 缓存在功能启动与手动刷新时重建（SPEC §9.2.4）。
    @Published private(set) var credentialConfiguredProviders: Set<TokenUsageProvider> = []

    /// 用量区块显隐（SPEC 4.3）：有数据或回填中才显示。
    var showingUsageBlock: Bool {
        hasUsageData || usageBackfilling
    }

    /// 是否有任何本地用量数据（日聚合缓存非空）。
    var hasUsageData: Bool {
        !usageDailyProviderAggregates.isEmpty
    }

    private let preferences: TokenUsagePreferences
    private let fetchers: [TokenUsageProvider: LimitsFetching]
    private let scheduler: RepeatingScheduling
    private let usageStore: UsageStoring?
    private let usageCollectors: [TokenUsageProvider: UsageCollecting]
    /// #11：告警触发器 — 随限额刷新同频评估（阈值/步速）。
    private let alerts: TokenUsageAlertManager?
    /// 限额重置监控 — 窗口 rollover 后触发庆祝（toast/撒花，按用户开关）。
    private let resetMonitor: TokenLimitResetMonitor?
    private var refreshTimer: AnyCancellable?
    /// 单飞合并：并发未命中共享同一次上游拉取，避免打爆 Claude OAuth 端点。
    private var inFlight = Set<TokenUsageProvider>()
    private var cancellables = Set<AnyCancellable>()
    /// 仪表盘快照代际：每次发起重建自增，晚到结果不覆盖新代际（SPEC §9.2.3）。
    private var dashboardGeneration = 0

    init(
        preferences: TokenUsagePreferences,
        fetchers: [TokenUsageProvider: LimitsFetching] = [:],
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        usageStore: UsageStoring? = nil,
        usageCollectors: [TokenUsageProvider: UsageCollecting] = [:],
        alerts: TokenUsageAlertManager? = nil,
        resetMonitor: TokenLimitResetMonitor? = nil
    ) {
        self.preferences = preferences
        self.fetchers = fetchers
        self.scheduler = scheduler
        self.usageStore = usageStore
        self.usageCollectors = usageCollectors
        self.alerts = alerts
        self.resetMonitor = resetMonitor

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
        refreshCredentialCache()
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
    /// 同时重建 Keychain 凭证缓存与仪表盘快照（用户可能刚保存/清除了凭证）。
    func refreshNow(force: Bool = false) {
        guard isActive else { return }
        refreshCredentialCache()
        rebuildDashboardSnapshot()
        refreshLimits(force: force)
    }

    /// 重建 Keychain/环境变量凭证缓存（读取较重，只在启动与显式刷新时执行）。
    private func refreshCredentialCache() {
        credentialConfiguredProviders = TokenUsageCredentialStateReader.configuredProviders()
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
        // 重置监控同频评估（内部按窗口 resetAt 前进 + 用量下降判定，快照防抖）。
        resetMonitor?.evaluate(limits: limits)
        // 轮询/刷新完成即自愈凭证缓存（低频，覆盖外部改动凭证的场景）。
        refreshCredentialCache()
        // 仅当有实际数据（新鲜成功或 last-good 回退）时推进「更新时间」，且取两者较新者。
        guard result.configured, result.issue == nil || !result.windows.isEmpty else { return }
        let captured = result.capturedAt
        if limitUpdateAt == nil || limitUpdateAt! < captured {
            limitUpdateAt = captured
        }
    }

    // MARK: - 用量侧（#04 / 仪表盘重设计）

    /// 汇总卡快照（今日/7天/30天/总计），按 provider 过滤（nil = 全部）。无数据时为零值卡。
    /// 主要供单元测试单项断言；面板渲染读 `dashboardSnapshot`（后台预计算）。
    func summaryCards(filteredBy provider: TokenUsageProvider?) -> UsageSummaryCards {
        TokenUsageDashboardSnapshotBuilder.summaryCards(
            filteredBy: provider,
            daily: usageDailyProviderAggregates,
            now: Date(),
            calendar: .current
        )
    }

    /// 活跃度年度热力图，按 provider 过滤。无数据 → nil（视图显示占位）。
    func activityHeatmap(filteredBy provider: TokenUsageProvider?) -> UsageActivityHeatmap? {
        TokenUsageDashboardSnapshotBuilder.heatmap(
            filteredBy: provider,
            daily: usageDailyProviderAggregates,
            now: Date(),
            calendar: .current
        )
    }

    /// 趋势点序列，按 provider 过滤 + 周期。对应周期无数据 → 空序列（视图显示占位）。
    func trendPoints(filteredBy provider: TokenUsageProvider?, period: TokenTrendPeriod) -> [UsageTrendPoint] {
        TokenUsageDashboardSnapshotBuilder.trendPoints(
            filteredBy: provider,
            period: period,
            daily: usageDailyProviderAggregates,
            store: usageStore,
            now: Date(),
            calendar: .current
        )
    }

    /// 模型 Top 列表，按 provider 过滤 + 周期窗口。无数据 → 空（视图隐藏该区）。
    func topModels(filteredBy provider: TokenUsageProvider?, period: TokenTrendPeriod) -> [UsageTopModelEntry] {
        TokenUsageDashboardSnapshotBuilder.topModels(
            filteredBy: provider,
            period: period,
            store: usageStore,
            now: Date(),
            calendar: .current
        )
    }

    /// 后台重建仪表盘快照（数据变化 / 显式刷新时调用）：
    /// 存储读取与全周期聚合在后台执行，主线程只赋值结果（SPEC §9.2.3）。
    private func rebuildDashboardSnapshot() {
        dashboardGeneration &+= 1
        let daily = usageDailyProviderAggregates
        let store = usageStore
        let generation = dashboardGeneration
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = TokenUsageDashboardSnapshotBuilder.make(
                daily: daily,
                store: store,
                now: Date()
            )
            await MainActor.run { [weak self] in
                guard let self, self.dashboardGeneration == generation else { return }
                self.dashboardSnapshot = snapshot
            }
        }
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
        // 全历史日聚合缓存（仪表盘汇总卡/热力图/趋势数据源；1970 起覆盖全部历史）。
        let historyStart = Date(timeIntervalSince1970: 0)
        let tomorrow = calendarTomorrow(now: now)
        usageDailyProviderAggregates = usageStore.loadDailyAggregates(
            from: historyStart,
            to: tomorrow,
            providers: nil
        )
        rebuildDashboardSnapshot()
    }

    private func calendarTomorrow(now: Date) -> Date {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now.addingTimeInterval(86_400)
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
