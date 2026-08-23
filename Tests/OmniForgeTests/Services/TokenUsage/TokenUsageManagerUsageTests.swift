import XCTest
@testable import OmniForge

/// Manager 接线：启停驱动采集器、用量快照发布/筛选、回填状态透传（SPEC 8）。
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

    func todayBuckets(total: Int, conversations: Int = 0, provider: TokenUsageProvider = .claude) -> UsageBucketState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let todayStart = calendar.startOfDay(for: Date())
        return UsageBucketState(
            key: UsageBucketKey(provider: provider, model: "deepseek-v4-flash", bucketStart: todayStart.addingTimeInterval(3600)),
            usage: TokenUsage(inputTokens: total, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total),
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
        XCTAssertEqual(manager.usageProvidersWithData, [.claude])
    }

    func test_usageDidChange_recomputesPublishedOverview() {
        let store = FakeUsageStore()
        let collector = FakeUsageCollector(provider: .claude)
        let manager = makeManager(store: store, collectors: [.claude: collector])
        manager.start()
        XCTAssertNil(manager.usageOverview, "无数据时为 nil → 用量区块隐藏")

        store.upsertBucket(todayBuckets(total: 42_000))
        collector.simulateUsageChanged()
        XCTAssertEqual(manager.usageOverview?.totalTokens, 42_000, "采集回调驱动快照刷新")
        XCTAssertEqual(manager.usageProvidersWithData, [.claude])
    }

    func test_usageOverview_forProvider_filtersByProvider() {
        let store = FakeUsageStore()
        store.upsertBucket(todayBuckets(total: 10, provider: .claude))
        store.upsertBucket(todayBuckets(total: 20, provider: .codex))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()
        XCTAssertEqual(manager.usageOverview?.totalTokens, 30, "聚合口径含全部 provider")
        XCTAssertEqual(manager.usageOverview(for: .claude)?.totalTokens, 10)
        XCTAssertEqual(manager.usageOverview(for: .codex)?.totalTokens, 20)
        XCTAssertNil(manager.usageOverview(for: .antigravity), "无数据 provider 无窗口数据 → nil")
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

    // MARK: - 周期化用量 / 分布（#05）

    private func bucket(daysAgo: Int, total: Int, conversations: Int = 0, provider: TokenUsageProvider = .claude, model: String = "deepseek-v4-flash") -> UsageBucketState {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        )
        return UsageBucketState(
            key: UsageBucketKey(provider: provider, model: model, bucketStart: dayStart.addingTimeInterval(3600)),
            usage: TokenUsage(inputTokens: total, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total),
            conversationCount: conversations
        )
    }

    func test_usageOverview_filteredByPeriod_appliesPeriodWindow() {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10))
        store.upsertBucket(bucket(daysAgo: 40, total: 999))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        XCTAssertEqual(manager.usageOverview(filteredBy: nil, period: .today)?.totalTokens, 10)
        XCTAssertEqual(manager.usageOverview(filteredBy: nil, period: .week)?.totalTokens, 10, "40 天前桶不在本周窗口")
        XCTAssertEqual(manager.usageOverview(filteredBy: nil, period: .month)?.totalTokens, 10, "40 天前桶不在本月窗口")
        XCTAssertEqual(manager.usageOverview(filteredBy: .claude, period: .week)?.totalTokens, 10)
        XCTAssertNil(manager.usageOverview(filteredBy: .antigravity, period: .week), "无数据 provider → nil")
    }

    func test_usageDistribution_reflectsProvidersWithData_automatically() throws {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10, provider: .claude, model: "opus"))
        store.upsertBucket(bucket(daysAgo: 0, total: 20, provider: .claude, model: "sonnet"))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let claudeOnly = try XCTUnwrap(manager.usageDistribution(filteredBy: nil, period: .today))
        XCTAssertEqual(claudeOnly.byProvider, [
            UsageDistributionEntry(label: "Claude", totalTokens: 30, provider: .claude)
        ], "只有 Claude 一家有数据时「按 Provider」仅 Claude 一行")
        XCTAssertEqual(claudeOnly.byModel.map(\.label), ["sonnet", "opus"])

        // 后续 provider 落地后自动出现（不做 Claude 特化）。
        store.upsertBucket(bucket(daysAgo: 0, total: 40, provider: .codex, model: "gpt-5"))
        let both = try XCTUnwrap(manager.usageDistribution(filteredBy: nil, period: .today))
        XCTAssertEqual(both.byProvider, [
            UsageDistributionEntry(label: "Codex", totalTokens: 40, provider: .codex),
            UsageDistributionEntry(label: "Claude", totalTokens: 30, provider: .claude),
        ])

        let codexOnly = try XCTUnwrap(manager.usageDistribution(filteredBy: .codex, period: .today))
        XCTAssertEqual(codexOnly.byProvider.map(\.provider), [.codex])
        XCTAssertEqual(codexOnly.byModel, [UsageDistributionEntry(label: "gpt-5", totalTokens: 40)])
    }

    func test_usageDistribution_selectsPeriodWindow() throws {
        let store = FakeUsageStore()
        store.upsertBucket(bucket(daysAgo: 0, total: 10))
        store.upsertBucket(bucket(daysAgo: 40, total: 999))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()

        let week = try XCTUnwrap(manager.usageDistribution(filteredBy: nil, period: .week))
        XCTAssertEqual(week.byModel.map(\.totalTokens), [10], "40 天前桶不入本周分布")
        let month = try XCTUnwrap(manager.usageDistribution(filteredBy: nil, period: .month))
        XCTAssertEqual(month.byModel.map(\.totalTokens), [10])
    }
}
