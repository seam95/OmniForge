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
        XCTAssertEqual(manager.usageOverview?.todayTotalTokens, 128_400)
        XCTAssertEqual(manager.usageOverview?.todayConversations, 3)
        XCTAssertEqual(manager.usageOverview?.sevenDay.map(\.totalTokens).reduce(0, +), 128_400)
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
        XCTAssertEqual(manager.usageOverview?.todayTotalTokens, 42_000, "采集回调驱动快照刷新")
        XCTAssertEqual(manager.usageProvidersWithData, [.claude])
    }

    func test_usageOverview_forProvider_filtersByProvider() {
        let store = FakeUsageStore()
        store.upsertBucket(todayBuckets(total: 10, provider: .claude))
        store.upsertBucket(todayBuckets(total: 20, provider: .codex))
        let manager = makeManager(store: store, collectors: [.claude: FakeUsageCollector(provider: .claude)])
        manager.start()
        XCTAssertEqual(manager.usageOverview?.todayTotalTokens, 30, "聚合口径含全部 provider")
        XCTAssertEqual(manager.usageOverview(for: .claude)?.todayTotalTokens, 10)
        XCTAssertEqual(manager.usageOverview(for: .codex)?.todayTotalTokens, 20)
        XCTAssertNil(manager.usageOverview(for: .gemini), "无数据 provider 无窗口数据 → nil")
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
}
