import XCTest
@testable import OmniForge

/// Manager 接线：启停驱动采集器、用量快照发布/筛选、回填状态透传（SPEC 8），
/// 以及仪表盘重设计后的汇总卡 / 热力图 / 趋势 / 模型 API（2026-08-25）。
@MainActor
final class TokenUsageManagerUsageTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "TokenUsageManagerUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeManager(
        store: FakeUsageStore,
        collectors: [TokenUsageProvider: FakeUsageCollector] = [:]
    ) -> TokenUsageManager {
        TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [:],
            scheduler: FakeRepeatingScheduler(),
            usageStore: store,
            usageCollectors: collectors
        )
    }

    private func usage(total: Int, conversations: Int = 0) -> TokenUsage {
        TokenUsage(
            inputTokens: total,
            cachedInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: total
        )
    }

    func todayBuckets(total: Int, conversations: Int = 0, provider: TokenUsageProvider = .claude) -> UsageBucketState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let todayStart = calendar.startOfDay(for: Date())
        return UsageBucketState(
            key: UsageBucketKey(provider: provider, model: "deepseek-v4-flash", bucketStart: todayStart.addingTimeInterval(3600)),
            usage: usage(total: total, conversations: conversations),
            conversationCount: conversations
        )
    }

    func test_start_and_stop_driveUsageCollectors() {
        let collector = FakeUsageCollector(provider: .claude)
        let manager = makeManager(store: FakeUsageStore(), collectors: [.claude: collector])
        manager.start()
        XCTAssertEqual(collector.startCount, 1)
        manager.stop()
        XCTAssertEqual(collector.stopCount, 1)
        XCTAssertFalse(manager.usageBackfilling)
    }

    func test_start_refreshesUsageSnapshotFromStore() {
        let store = FakeUsageStore()
        store.upsertBucket(todayBuckets(total: 128_400, conversations: 3))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()
        XCTAssertEqual(manager.usageOverview?.totalTokens, 128_400)
        XCTAssertEqual(manager.usageOverview?.conversations, 3)
        XCTAssertEqual(manager.usageOverview?.daily.map(\.totalTokens).reduce(0, +), 128_400)
        XCTAssertTrue(manager.hasUsageData)
        XCTAssertEqual(manager.summaryCards(filteredBy: nil).todayTokens, 128_400)
        XCTAssertEqual(manager.summaryCards(filteredBy: nil).todayConversations, 3)
    }

    func test_usageDidChange_recomputesPublishedOverview() {
        let store = FakeUsageStore()
        let collector = FakeUsageCollector(provider: .claude)
        let manager = makeManager(store: store, collectors: [.claude: collector])
        manager.start()
        XCTAssertNil(manager.usageOverview, "无数据时为 nil → 用量区块隐藏")
        XCTAssertFalse(manager.hasUsageData)

        store.upsertBucket(todayBuckets(total: 42_000))
        collector.simulateUsageChanged()
        XCTAssertEqual(manager.usageOverview?.totalTokens, 42_000, "采集回调驱动快照刷新")
        XCTAssertTrue(manager.hasUsageData)
        XCTAssertEqual(manager.summaryCards(filteredBy: nil).todayTokens, 42_000)
    }

    func test_summaryCards_filtersByProvider() {
        let store = FakeUsageStore()
        store.upsertBucket(todayBuckets(total: 10, provider: .claude))
        store.upsertBucket(todayBuckets(total: 20, provider: .codex))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()
        XCTAssertEqual(manager.summaryCards(filteredBy: nil).todayTokens, 30, "聚合口径含全部 provider")
        XCTAssertEqual(manager.summaryCards(filteredBy: .claude).todayTokens, 10)
        XCTAssertEqual(manager.summaryCards(filteredBy: .codex).todayTokens, 20)
        XCTAssertEqual(manager.summaryCards(filteredBy: .antigravity).todayTokens, 0, "无数据 provider → 0")
    }

    func test_usageBackfilling_tracksCollector() {
        let collector = FakeUsageCollector(provider: .claude)
        let manager = makeManager(store: FakeUsageStore(), collectors: [.claude: collector])
        manager.start()
        XCTAssertFalse(manager.usageBackfilling)
        collector.simulateBackfill(true)
        XCTAssertTrue(manager.usageBackfilling)
        XCTAssertTrue(manager.showingUsageBlock, "回填中用量区块也应显示")
        collector.simulateBackfill(false)
        XCTAssertFalse(manager.usageBackfilling)
    }

    func test_noStore_usageSnapshotNil() {
        let collector = FakeUsageCollector(provider: .claude)
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [:],
            scheduler: FakeRepeatingScheduler(),
            usageCollectors: [.claude: collector]
        )
        manager.start()
        XCTAssertNil(manager.usageOverview)
        XCTAssertFalse(manager.showingUsageBlock)
    }

    // MARK: - 仪表盘 API（汇总卡 / 趋势 / 热力图 / 模型）

    private func bucket(daysAgo: Int, total: Int, conversations: Int = 0, provider: TokenUsageProvider = .claude, model: String = "deepseek-v4-flash") -> UsageBucketState {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        )
        return UsageBucketState(
            key: UsageBucketKey(provider: provider, model: model, bucketStart: dayStart.addingTimeInterval(3600)),
            usage: usage(total: total, conversations: conversations),
            conversationCount: conversations
        )
    }

    private func bucket(at date: Date, total: Int, conversations: Int = 0, provider: TokenUsageProvider = .claude, model: String = "deepseek-v4-flash") -> UsageBucketState {
        UsageBucketState(
            key: UsageBucketKey(provider: provider, model: model, bucketStart: date),
            usage: usage(total: total, conversations: conversations),
            conversationCount: conversations
        )
    }

    func test_summaryCards_reflectsWindowsAndActiveDays() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 100, conversations: 3))
        store.upsertBucket(bucket(daysAgo: 2, total: 200))
        store.upsertBucket(bucket(daysAgo: 40, total: 400))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let cards = manager.summaryCards(filteredBy: nil)
        XCTAssertEqual(cards.todayTokens, 100)
        XCTAssertEqual(cards.todayConversations, 3)
        XCTAssertEqual(cards.last7dTokens, 300)
        XCTAssertEqual(cards.last7dActiveDays, 2)
        XCTAssertEqual(cards.last30dTokens, 300, "40 天前不在 30 日窗口")
        XCTAssertEqual(cards.last30dAvgPerActiveDay, 150)
        XCTAssertEqual(cards.totalTokens, 700)
        XCTAssertEqual(cards.totalActiveDays, 3)
    }

    func test_trendPoints_day_aggregatesBucketsByHourUpToNow() {
        let store = FakeUsageStore()
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let todayStart = calendar.startOfDay(for: now)
        // 当前小时桶（避免跨零点/当前小时边界造成的确定性波动）。
        store.upsertBucket(bucket(at: todayStart.addingTimeInterval(TimeInterval(currentHour * 3600 + 60)), total: 42))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let points = manager.trendPoints(filteredBy: nil, period: .day)
        XCTAssertEqual(points.count, currentHour + 1, "逐时补零至当前小时")
        XCTAssertEqual(points.last?.tokens, 42)
        XCTAssertEqual(points.prefix(points.count - 1).reduce(0) { $0 + $1.tokens }, 0, "其余小时补零")
    }

    func test_trendPoints_weekAndMonth_fillDailyZeros() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 100))
        store.upsertBucket(bucket(daysAgo: 40, total: 999))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let week = manager.trendPoints(filteredBy: nil, period: .week)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.reduce(0) { $0 + $1.tokens }, 100, "40 天前不在近 7 日")
        let month = manager.trendPoints(filteredBy: nil, period: .month)
        XCTAssertEqual(month.count, 30)
        XCTAssertEqual(month.reduce(0) { $0 + $1.tokens }, 100, "40 天前不在近 30 日")
    }

    func test_trendPoints_total_groupsByMonth() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 100))
        store.upsertBucket(bucket(daysAgo: 40, total: 999))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let total = manager.trendPoints(filteredBy: nil, period: .total)
        XCTAssertFalse(total.isEmpty)
        XCTAssertEqual(total.reduce(0) { $0 + $1.tokens }, 1099, "总计含全部历史，按月归并")
    }

    func test_trendPoints_filtersByProvider() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10, provider: .claude))
        store.upsertBucket(bucket(daysAgo: 0, total: 20, provider: .codex))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        XCTAssertEqual(manager.trendPoints(filteredBy: .claude, period: .week).reduce(0) { $0 + $1.tokens }, 10)
        XCTAssertEqual(manager.trendPoints(filteredBy: .codex, period: .week).reduce(0) { $0 + $1.tokens }, 20)
        XCTAssertEqual(manager.trendPoints(filteredBy: .antigravity, period: .week).reduce(0) { $0 + $1.tokens }, 0)
    }

    func test_topModels_aggregatesByModelForWindow() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 30, model: "opus"))
        store.upsertBucket(bucket(daysAgo: 0, total: 70, model: "sonnet"))
        store.upsertBucket(bucket(daysAgo: 40, total: 1000, model: "sonnet"))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let week = manager.topModels(filteredBy: nil, period: .week)
        XCTAssertEqual(week.map(\.name), ["sonnet", "opus"])
        XCTAssertEqual(week.map(\.tokens), [70, 30])
        XCTAssertEqual(week[0].percent, 70.0, accuracy: 0.001)

        let total = manager.topModels(filteredBy: nil, period: .total)
        XCTAssertEqual(total.first?.name, "sonnet")
        XCTAssertEqual(total.first?.tokens, 1070)
    }

    func test_topModels_filtersByProvider() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10, provider: .claude, model: "opus"))
        store.upsertBucket(bucket(daysAgo: 0, total: 20, provider: .codex, model: "gpt-5"))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let claudeOnly = manager.topModels(filteredBy: .claude, period: .week)
        XCTAssertEqual(claudeOnly.map(\.name), ["opus"])
        XCTAssertEqual(claudeOnly.first?.percent ?? 0, 100.0, accuracy: 0.001)
        let nilFilter = manager.topModels(filteredBy: nil, period: .week)
        XCTAssertEqual(nilFilter.map(\.name), ["gpt-5", "opus"])
    }

    func test_activityHeatmap_buildsWeeksAndActiveDays() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10))
        store.upsertBucket(bucket(daysAgo: 3, total: 20))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let heatmap = manager.activityHeatmap(filteredBy: nil)
        XCTAssertNotNil(heatmap)
        XCTAssertEqual(heatmap?.activeDays, 2)
        XCTAssertEqual(heatmap?.weeks.count, 53)

        // 今日格有数据且强度 ≥ 1；末列某天数据存在。
        let todayCells = heatmap?.weeks.flatMap { $0.compactMap { $0 } }
            .filter { Calendar.current.isDate($0.dayStart, inSameDayAs: Date()) } ?? []
        XCTAssertEqual(todayCells.first?.totalTokens, 10)
        XCTAssertGreaterThanOrEqual(todayCells.first?.level ?? 0, 1)
    }

    func test_activityHeatmap_filtersByProvider() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10, provider: .claude))
        store.upsertBucket(bucket(daysAgo: 0, total: 20, provider: .codex))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        XCTAssertEqual(manager.activityHeatmap(filteredBy: .claude)?.activeDays, 1)
        XCTAssertEqual(manager.activityHeatmap(filteredBy: .codex)?.activeDays, 1)
        XCTAssertNil(manager.activityHeatmap(filteredBy: .antigravity), "无数据 provider → nil")
    }
}
