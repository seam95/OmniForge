import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// SPEC §9.2.2：Token 面板渲染路径零存储访问——空周期为合法快照结果，
/// 快照未就绪给空展示；重复渲染 / 冷启动期间存储读取计数不变。
@MainActor
final class TokenUsagePanelRenderPathTests: XCTestCase {

    // MARK: - 渲染数据解析（纯类型）

    func test_renderData_nilDashboard_resolvesToEmptyWithoutFallback() {
        let data = TokenPanelUsageRenderData(dashboard: nil, period: .day)
        XCTAssertTrue(data.trendPoints.isEmpty, "快照未就绪 → 空展示（视图占位），不查询")
        XCTAssertTrue(data.topModels.isEmpty)
    }

    func test_renderData_emptyPeriodLists_areValidResults() {
        // 快照存在但该周期无模型数据：空列表是合法结果，不回退查询。
        let snapshot = TokenUsageDashboardSnapshot(
            summaryCards: .zero,
            heatmap: nil,
            trendPoints: [.day: []],
            topModels: [:],
            updatedAt: Date()
        )
        let data = TokenPanelUsageRenderData(dashboard: snapshot, period: .day)
        XCTAssertEqual(data.trendPoints, [], "空趋势点为合法结果")
        XCTAssertTrue(data.topModels.isEmpty, "缺失键（全周期无模型）同样解析为空")
    }

    // MARK: - 快照构建：空周期必须产生键（防「空=未命中」回归）

    func test_dashboardSnapshot_keepsEmptyPeriodsAsValidEntries() async throws {
        let store = FakeUsageStore()
        // 只有用量桶、无模型维度差异（单模型）；day 周期仍可能为空。
        store.upsertBucket(bucketFixture(daysAgo: 0, total: 100))
        let manager = makeManager(store: store)
        manager.start()

        try await waitUntil { manager.dashboardSnapshot != nil }
        let snapshot = try XCTUnwrap(manager.dashboardSnapshot)

        for period in TokenTrendPeriod.allCases {
            XCTAssertNotNil(
                snapshot.topModels[period],
                "\(period)：即使无数据也必须写入空列表键（合法结果，非未命中）"
            )
            XCTAssertNotNil(snapshot.trendPoints[period], "\(period)：趋势点键必须存在")
        }
    }

    // MARK: - 渲染循环零存储访问（SPEC §9.2.2）

    /// 挂载真实面板并触发多次重渲染：快照就绪后，存储读取计数不得增加。
    func test_panelRenderLoop_doesNotReadStore() async throws {
        let store = CountingUsageStore(base: FakeUsageStore())
        store.base.upsertBucket(bucketFixture(daysAgo: 0, total: 100))
        let prefs = TokenUsagePreferences(userDefaults: makeDefaults())
        let manager = TokenUsageManager(
            preferences: prefs,
            fetchers: [.claude: StubLimitsFetcher(provider: .claude, results: [.success(.notConfigured(.claude))])],
            scheduler: FakeRepeatingScheduler(),
            usageStore: store
        )
        manager.start()
        // 等 limits 就位（否则面板显示骨架态，渲染不到用量分区）与快照就绪。
        try await waitUntil { !manager.limits.isEmpty && manager.dashboardSnapshot != nil }
        try await Task.sleep(nanoseconds: 100_000_000) // 让后台 rebuild 全部落定

        let counter = RenderCounter()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: PanelRenderHarness(manager: manager, preferences: prefs, tick: counter)
        )
        window.orderFrontRegardless()
        try await waitUntil { counter.renders >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)

        let baseline = store.readTotal
        for _ in 0..<5 {
            counter.bump()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(
            store.readTotal, baseline,
            "重复渲染不得触发存储读取（SPEC §9.2.2），读取明细：buckets=\(store.bucketReads) models=\(store.modelReads) daily=\(store.dailyReads)"
        )
    }

    // MARK: - 工具

    private func makeManager(store: FakeUsageStore) -> TokenUsageManager {
        TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [:],
            scheduler: FakeRepeatingScheduler(),
            usageStore: store
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TokenUsagePanelRenderPathTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func bucketFixture(daysAgo: Int, total: Int) -> UsageBucketState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.date(byAdding: .day, value: daysAgo, to: Date())!
        let start = calendar.startOfDay(for: day).addingTimeInterval(3600)
        return UsageBucketState(
            key: UsageBucketKey(provider: .claude, model: "probe-model", bucketStart: start),
            usage: TokenUsage(
                inputTokens: total, cachedInputTokens: 0, cacheCreationInputTokens: 0,
                outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total
            ),
            conversationCount: 1
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { XCTFail("等待条件超时") }
    }
}

/// 重渲染驱动器：bump 改变状态触发 harness body 重算。
@MainActor
final class RenderCounter: ObservableObject {
    @Published private(set) var value = 0
    private(set) var renders = 0

    func bump() { value &+= 1 }

    func markRender() { renders &+= 1 }
}

private struct PanelRenderHarness: View {
    @ObservedObject var manager: TokenUsageManager
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject var tick: RenderCounter

    var body: some View {
        let _ = tick.value // 依赖 tick：bump 即触发本 body 重算
        let _ = tick.markRender()
        return TokenUsagePanelView(
            manager: manager,
            preferences: preferences,
            balanceManager: nil,
            strings: .en
        )
        .frame(width: 380)
    }
}

/// 计数 store：转发全部读取到内部 FakeUsageStore，只统计读操作。
final class CountingUsageStore: UsageStoring {
    let base: FakeUsageStore
    private(set) var bucketReads = 0
    private(set) var modelReads = 0
    private(set) var dailyReads = 0

    var readTotal: Int { bucketReads + modelReads + dailyReads }

    init(base: FakeUsageStore) {
        self.base = base
    }

    func upsertBucket(_ state: UsageBucketState) { base.upsertBucket(state) }
    func loadBucket(_ key: UsageBucketKey) -> UsageBucketState? {
        bucketReads += 1
        return base.loadBucket(key)
    }

    func loadBuckets(
        from start: Date, to end: Date, providers: Set<TokenUsageProvider>?
    ) -> [UsageBucketState] {
        bucketReads += 1
        return base.loadBuckets(from: start, to: end, providers: providers)
    }

    func loadDailyAggregates(
        from start: Date, to end: Date, providers: Set<TokenUsageProvider>?
    ) -> [UsageDayProviderAggregate] {
        dailyReads += 1
        return base.loadDailyAggregates(from: start, to: end, providers: providers)
    }

    func loadModelAggregates(
        from start: Date, to end: Date, providers: Set<TokenUsageProvider>?
    ) -> [UsageModelAggregate] {
        modelReads += 1
        return base.loadModelAggregates(from: start, to: end, providers: providers)
    }

    func loadSeenKeys() -> Set<String> { base.loadSeenKeys() }
    func storeSeenKeys(_ keys: Set<String>, asOf date: Date) {
        base.storeSeenKeys(keys, asOf: date)
    }

    func loadCursors() -> [String: JSONLCursor] { base.loadCursors() }
    func storeCursor(path: String, cursor: JSONLCursor) { base.storeCursor(path: path, cursor: cursor) }
    func removeCursor(path: String) { base.removeCursor(path: path) }
    func clearCursors() { base.clearCursors() }
    func loadProviderMessageState(_ provider: TokenUsageProvider) -> [String: String] {
        base.loadProviderMessageState(provider)
    }

    func storeProviderMessageState(
        _ provider: TokenUsageProvider, entries: [String: String]
    ) {
        base.storeProviderMessageState(provider, entries: entries)
    }
}
