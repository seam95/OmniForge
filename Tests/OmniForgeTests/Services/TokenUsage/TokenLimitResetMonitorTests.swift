import XCTest
@testable import OmniForge

/// 限额重置监控 — 随限额快照评估 rollover，按用户开关回调庆祝副作用。
final class TokenLimitResetMonitorTests: XCTestCase {

    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "TokenLimitResetMonitorTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeMonitor(
        config: TokenUsageConfiguration = TokenUsageConfiguration(),
        now: Double = 1_704_800_100,
        defaults: UserDefaults? = nil
    ) -> TokenLimitResetMonitor {
        let monitor = TokenLimitResetMonitor(
            configuration: { config },
            stringsProvider: { .en },
            userDefaults: defaults ?? UserDefaults(suiteName: suite)!,
            now: { Date(timeIntervalSince1970: now) }
        )
        return monitor
    }

    private func makeRolledOverLimits() -> [TokenUsageProvider: ProviderUsageLimits] {
        // 首次 evaluate 记基线；第二次喂「reset_at 前进 + 用量骤降」触发 rollover。
        let window: [LimitWindowKind: UsageWindow] = [
            .weekly: UsageWindow(
                usedPercent: 8,
                resetAt: Date(timeIntervalSince1970: 1_704_800_000)
            )
        ]
        return [
            .codex: ProviderUsageLimits(
                provider: .codex,
                configured: true,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: window,
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: nil
            )
        ]
    }

    private func makeBaselineLimits() -> [TokenUsageProvider: ProviderUsageLimits] {
        let window: [LimitWindowKind: UsageWindow] = [
            .weekly: UsageWindow(
                usedPercent: 90,
                resetAt: Date(timeIntervalSince1970: 1_600_000_000)
            )
        ]
        return [
            .codex: ProviderUsageLimits(
                provider: .codex,
                configured: true,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: window,
                confidence: .official,
                capturedAt: Date(),
                stale: false,
                issue: nil
            )
        ]
    }

    func test_rollover_firesCelebrationWithDefaults() {
        let monitor = makeMonitor()
        var celebrated: (event: LimitResetEvent, toast: Bool, confetti: Bool)?
        monitor.onCelebrate = { event, toast, confetti in
            celebrated = (event, toast, confetti)
        }

        monitor.evaluate(limits: makeBaselineLimits(), at: Date(timeIntervalSince1970: 1_704_800_000))
        monitor.evaluate(limits: makeRolledOverLimits(), at: Date(timeIntervalSince1970: 1_704_800_100))

        XCTAssertNotNil(celebrated)
        XCTAssertEqual(celebrated?.event.provider, .codex)
        XCTAssertEqual(celebrated?.event.windowLabel, "7d")
        XCTAssertEqual(celebrated?.event.previousPercent, 90)
        XCTAssertTrue(celebrated!.toast, "默认开：显示提示")
        XCTAssertTrue(celebrated!.confetti, "默认开：撒花")
    }

    func test_bothTogglesOff_noCallback() {
        var config = TokenUsageConfiguration()
        config.resetToastEnabled = false
        config.resetConfettiEnabled = false
        let monitor = makeMonitor(config: config)
        var callCount = 0
        monitor.onCelebrate = { _, _, _ in callCount += 1 }

        monitor.evaluate(limits: makeBaselineLimits(), at: Date(timeIntervalSince1970: 1_704_800_000))
        monitor.evaluate(limits: makeRolledOverLimits(), at: Date(timeIntervalSince1970: 1_704_800_100))

        XCTAssertEqual(callCount, 0, "提示与撒花双关 → 完全不庆祝")
    }

    func test_onlyConfettiEnabled_callbackRespectsFlags() {
        var config = TokenUsageConfiguration()
        config.resetToastEnabled = false
        let monitor = makeMonitor(config: config)
        var captured: (toast: Bool, confetti: Bool)?
        monitor.onCelebrate = { _, toast, confetti in captured = (toast, confetti) }

        monitor.evaluate(limits: makeBaselineLimits(), at: Date(timeIntervalSince1970: 1_704_800_000))
        monitor.evaluate(limits: makeRolledOverLimits(), at: Date(timeIntervalSince1970: 1_704_800_100))

        XCTAssertEqual(captured?.toast, false)
        XCTAssertEqual(captured?.confetti, true)
    }

    func test_noRollover_noCallback() {
        let monitor = makeMonitor()
        var callCount = 0
        monitor.onCelebrate = { _, _, _ in callCount += 1 }

        monitor.evaluate(limits: makeBaselineLimits(), at: Date(timeIntervalSince1970: 1_704_800_000))
        // 仅百分比小幅波动，reset_at 未前进 → 不触发
        var sameWindow = makeBaselineLimits()
        var codex = sameWindow[.codex]!
        codex.windows[.weekly]?.usedPercent = 88
        sameWindow[.codex] = codex
        monitor.evaluate(limits: sameWindow, at: Date(timeIntervalSince1970: 1_704_800_100))

        XCTAssertEqual(callCount, 0)
    }

    func test_snapshotPersistsBetweenEvaluations() {
        let defaults = UserDefaults(suiteName: suite)!
        let monitor = makeMonitor(defaults: defaults)
        var callCount = 0
        monitor.onCelebrate = { _, _, _ in callCount += 1 }

        // 第一次完整周期：基线 → rollover，触发一次
        monitor.evaluate(limits: makeBaselineLimits(), at: Date(timeIntervalSince1970: 1_704_800_000))
        monitor.evaluate(limits: makeRolledOverLimits(), at: Date(timeIntervalSince1970: 1_704_800_100))
        XCTAssertEqual(callCount, 1)

        // 用新 monitor 实例 + 同一 UserDefaults：快照已落盘，冷却期内不重复
        let second = TokenLimitResetMonitor(
            configuration: { TokenUsageConfiguration() },
            stringsProvider: { .en },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_704_800_200) }
        )
        second.onCelebrate = { _, _, _ in callCount += 1 }
        second.evaluate(limits: makeRolledOverLimits(), at: Date(timeIntervalSince1970: 1_704_800_200))

        XCTAssertEqual(callCount, 1, "重启后冷却记忆仍在 → 不重复庆祝")
    }

    // MARK: - 与 TokenUsageManager 同频接线

    @MainActor
    func test_managerRefreshDrivesResetCelebration() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        let baseline: [LimitWindowKind: UsageWindow] = [
            .weekly: UsageWindow(usedPercent: 90, resetAt: Date(timeIntervalSince1970: 1_600_000_000))
        ]
        let rolledOver: [LimitWindowKind: UsageWindow] = [
            .weekly: UsageWindow(usedPercent: 8, resetAt: Date(timeIntervalSince1970: 1_704_800_000))
        ]
        let fetcher = StubLimitsFetcher(provider: .codex, results: [
            .success(makeLimits(provider: .codex, windows: baseline)),
            .success(makeLimits(provider: .codex, windows: rolledOver)),
        ])
        let monitor = TokenLimitResetMonitor(
            configuration: { TokenUsageConfiguration() },
            stringsProvider: { .en },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_704_800_100) }
        )
        var celebrated = false
        monitor.onCelebrate = { event, _, _ in
            celebrated = true
            XCTAssertEqual(event.provider, .codex)
            XCTAssertEqual(event.windowLabel, "7d")
            XCTAssertEqual(event.previousPercent, 90)
        }
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: defaults),
            fetchers: [.codex: fetcher],
            scheduler: FakeRepeatingScheduler(),
            resetMonitor: monitor
        )
        manager.start()
        try await waitUntil { fetcher.callCount == 1 }
        XCTAssertFalse(celebrated, "首次取数只记基线")
        manager.refreshNow(force: true)
        try await waitUntil { fetcher.callCount == 2 }
        XCTAssertTrue(celebrated, "第二次取数窗口 rollover → 触发庆祝")
    }

    private func makeLimits(
        provider: TokenUsageProvider,
        windows: [LimitWindowKind: UsageWindow]
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: windows,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("waitUntil timed out")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
