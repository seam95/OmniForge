import Combine
import XCTest
import AppKit
@testable import OmniForge

/// StatusBarController 的 token 菜单栏贡献接线（#06）：门控 isAvailable + 偏好 + 用量快照。
@MainActor
final class StatusBarControllerTokenUsageTests: XCTestCase {
    private var suiteName: String?
    private var defaults: UserDefaults?

    override func setUp() {
        super.setUp()
        // isAvailable(.tokenUsage) 读取 UserDefaults.standard
        UserDefaults.standard.set(true, forKey: AppFeature.tokenUsage.availabilityKey)
        let suite = "StatusBarControllerTokenUsageTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        Defaults.register(in: d)
        suiteName = suite
        defaults = d
    }

    override func tearDown() {
        FeatureRuntime.shared.unregisterAll(for: .tokenUsage)
        UserDefaults.standard.removeObject(forKey: AppFeature.tokenUsage.availabilityKey)
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeController() -> (
        controller: StatusBarController,
        manager: TokenUsageManager,
        prefs: TokenUsagePreferences,
        store: FakeUsageStore,
        collector: FakeUsageCollector,
        expectedLabel: String
    ) {
        guard let defaults else { fatalError("defaults not ready") }
        let store = FakeUsageStore()
        let collector = FakeUsageCollector(provider: .claude)
        let prefs = TokenUsagePreferences(userDefaults: defaults)
        let manager = TokenUsageManager(
            preferences: prefs,
            fetchers: [:],
            scheduler: FakeRepeatingScheduler(),
            usageStore: store,
            usageCollectors: [.claude: collector]
        )
        FeatureRuntime.shared.register(.tokenUsage, manager: manager)
        FeatureRuntime.shared.register(.tokenUsage, manager: prefs)

        let l10n = L10n(userDefaults: defaults)
        let state = AppState(
            l10n: l10n,
            launchAtLogin: LaunchAtLoginManager(
                client: FakeLaunchAtLoginClient(),
                userDefaults: defaults
            ),
            userDefaults: defaults
        )
        XCTAssertNotNil(state.tokenUsageManager, "AppState 应回绑 FeatureRuntime 注册的 manager")

        let controller = StatusBarController(
            state: state,
            clipboardWindowController: ClipboardWindowController(state: state)
        )
        return (controller, manager, prefs, store, collector, l10n.s.tokenMenuBarTodayLabel)
    }

    func test_tokenMenuBar_showsTodayTokensOnlyAfterUsageDataArrives() {
        let (controller, manager, _, store, collector, expectedLabel) = makeController()

        XCTAssertNil(controller.tokenMenuBarRenderForTesting?.block, "无数据时不显示")
        XCTAssertNil(controller.tokenMenuBarItemVisibleForTesting, "无数据时不创建状态项")

        manager.start()
        XCTAssertNil(controller.tokenMenuBarRenderForTesting?.block)

        store.upsertBucket(todayBuckets(total: 128_400))
        collector.simulateUsageChanged()
        let shown = runMainLoopUntil { controller.tokenMenuBarRenderForTesting?.block != nil }

        XCTAssertTrue(shown, "用量快照应驱动菜单栏显示今日 tokens")
        XCTAssertEqual(controller.tokenMenuBarRenderForTesting?.block?.label, expectedLabel)
        XCTAssertEqual(controller.tokenMenuBarRenderForTesting?.block?.value, "128k")
        XCTAssertEqual(controller.tokenMenuBarRenderForTesting?.block?.minimumValue, "999k")
        XCTAssertEqual(controller.tokenMenuBarItemVisibleForTesting, true)
    }

    func test_tokenMenuBar_modeHidden_hidesImmediately() {
        let (controller, manager, prefs, store, collector, _) = makeController()
        manager.start()
        store.upsertBucket(todayBuckets(total: 42_000))
        collector.simulateUsageChanged()
        XCTAssertTrue(runMainLoopUntil { controller.tokenMenuBarRenderForTesting?.block != nil })
        XCTAssertEqual(controller.tokenMenuBarRenderForTesting?.block?.value, "42k")
        XCTAssertEqual(controller.tokenMenuBarItemVisibleForTesting, true)

        prefs.update { $0.menuBarMode = .hidden }
        let hidden = runMainLoopUntil { controller.tokenMenuBarRenderForTesting?.block == nil }

        XCTAssertTrue(hidden, "偏好切换「关闭」应即时生效")
        XCTAssertEqual(controller.tokenMenuBarItemVisibleForTesting, false)
    }

    func test_tokenMenuBar_uninstallFeature_removesItem() {
        let (controller, manager, _, store, collector, _) = makeController()
        manager.start()
        store.upsertBucket(todayBuckets(total: 42_000))
        collector.simulateUsageChanged()
        XCTAssertTrue(runMainLoopUntil { controller.tokenMenuBarItemVisibleForTesting == true })

        FeatureRuntime.shared.setAvailable(.tokenUsage, false)
        let removed = runMainLoopUntil {
            controller.tokenMenuBarItemVisibleForTesting == nil
        }

        XCTAssertTrue(removed, "卸载后应移出菜单栏状态项")
        XCTAssertNil(controller.tokenMenuBarRenderForTesting?.block)
    }

    // MARK: - 辅助

    private func todayBuckets(total: Int, conversations: Int = 0) -> UsageBucketState {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        return UsageBucketState(
            key: UsageBucketKey(
                provider: .claude,
                model: "test-model",
                bucketStart: todayStart.addingTimeInterval(3600)
            ),
            usage: TokenUsage(
                inputTokens: total,
                cachedInputTokens: 0,
                cacheCreationInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: total
            ),
            conversationCount: conversations
        )
    }

    private func runMainLoopUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
