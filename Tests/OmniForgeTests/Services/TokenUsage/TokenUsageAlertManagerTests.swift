import XCTest
@testable import OmniForge

/// #11：Token 用量告警 — 会话窗阈值（≥90%，对齐 TokenTracker）/ 步速超前（LimitPace.paceOver）/
/// 同窗防抖 / 独立开关 / 未授权静默降级。
@MainActor
final class TokenUsageAlertManagerTests: XCTestCase {
    private func makeSessionWindow(
        percent: Double,
        resetAt: Date? = nil,
        windowSeconds: Double? = 18000
    ) -> UsageWindow {
        UsageWindow(
            usedPercent: percent,
            resetAt: resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: windowSeconds
        )
    }

    private func makeLimits(
        provider: TokenUsageProvider = .claude,
        configured: Bool = true,
        issue: LimitError? = nil,
        stale: Bool = false,
        sessionWindow: UsageWindow? = nil
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: configured,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: sessionWindow.map { [.session: $0] } ?? [:],
            confidence: .official,
            capturedAt: Date(),
            stale: stale,
            issue: issue
        )
    }

    // MARK: - 阈值告警（会话窗 ≥90%）

    private let thresholdTestPoint = Date(timeIntervalSince1970: 1_000_000)

    /// 距重置 30 分钟时均匀应已用 90%：used ≤ 92% 不会误触步速，测试只验证阈值。
    private func thresholdWindow(percent: Double, resetAt: Date? = nil) -> UsageWindow {
        makeSessionWindow(percent: percent, resetAt: resetAt ?? thresholdTestPoint.addingTimeInterval(1800))
    }

    func test_sessionThresholdAt90PostsNotification() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 90))
        manager.evaluate(snapshot, at: thresholdTestPoint)
        XCTAssertEqual(client.posted.count, 1)
        XCTAssertEqual(client.posted[0].title, Strings.en.tokenAlertSessionTitle)
        XCTAssertEqual(
            client.posted[0].body,
            String(format: Strings.en.tokenAlertSessionBodyFormat, "Claude", 90)
        )
    }

    func test_sessionThresholdJustBelow90DoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 89.9))
        manager.evaluate(snapshot, at: thresholdTestPoint)
        XCTAssertTrue(client.posted.isEmpty)
    }

    func test_sessionThresholdAlertDisabledDoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        var config = TokenUsageConfiguration()
        config.sessionLimitAlertEnabled = false
        let manager = makeManager(client: client, configuration: config)
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 92))
        manager.evaluate(snapshot, at: thresholdTestPoint)
        XCTAssertTrue(client.posted.isEmpty, "阈值告警关闭时应静默不推送")
    }

    // MARK: - 步速告警（LimitPace 将提前用尽）

    func test_paceOverrunPostsNotification() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let t = Date(timeIntervalSince1970: 1_000_000)
        // 5h 窗剩 1h40m（expected ≈ 66.7%），已用 80% > 期望 + 3pp → 超前；但 <90% 不触发阈值。
        let snapshot = makeLimits(
            sessionWindow: makeSessionWindow(percent: 80, resetAt: t.addingTimeInterval(6000))
        )
        manager.evaluate(snapshot, at: t)
        XCTAssertEqual(client.posted.count, 1)
        XCTAssertEqual(client.posted[0].title, Strings.en.tokenAlertPaceTitle)
        XCTAssertEqual(
            client.posted[0].body,
            String(format: Strings.en.tokenAlertPaceBodyFormat, "Claude")
        )
    }

    func test_paceWithinToleranceDoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let t = Date(timeIntervalSince1970: 1_000_000)
        // expected 66.7%，已用 60% 落后或未超容差 → 不超前。
        let snapshot = makeLimits(
            sessionWindow: makeSessionWindow(percent: 60, resetAt: t.addingTimeInterval(6000))
        )
        manager.evaluate(snapshot, at: t)
        XCTAssertTrue(client.posted.isEmpty)
    }

    func test_paceAlertDisabledDoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        var config = TokenUsageConfiguration()
        config.paceOverrunAlertEnabled = false
        let manager = makeManager(client: client, configuration: config)
        let t = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = makeLimits(
            sessionWindow: makeSessionWindow(percent: 80, resetAt: t.addingTimeInterval(6000))
        )
        manager.evaluate(snapshot, at: t)
        XCTAssertTrue(client.posted.isEmpty, "步速告警关闭时应静默不推送")
    }

    // MARK: - 防抖（同窗同告警在 reset 前不重复）

    func test_sameWindowAlertDebouncedUntilReset() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let t = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 90, resetAt: t.addingTimeInterval(1800)))
        manager.evaluate(snapshot, at: t)
        manager.evaluate(snapshot, at: t.addingTimeInterval(600))
        manager.evaluate(snapshot, at: t.addingTimeInterval(1800))
        XCTAssertEqual(client.posted.count, 1, "同一窗口同一告警在 reset 前不重复推送")
    }

    func test_alertFiresAgainNewWindowAfterReset() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let t = Date(timeIntervalSince1970: 1_000_000)
        let first = makeLimits(
            sessionWindow: thresholdWindow(percent: 90, resetAt: t.addingTimeInterval(1800))
        )
        manager.evaluate(first, at: t)
        XCTAssertEqual(client.posted.count, 1)
        // 窗口已重置（新 resetAt，评估时刻距重置仍 30 分钟）→ 同告警可再次触发。
        let second = makeLimits(
            sessionWindow: thresholdWindow(percent: 90, resetAt: t.addingTimeInterval(5400))
        )
        manager.evaluate(second, at: t.addingTimeInterval(3600))
        XCTAssertEqual(client.posted.count, 2, "窗口 reset 后同告警应可再次触发")
    }

    // MARK: - 两类告警独立

    func test_thresholdAndPaceBothTriggerIndependently() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let t = Date(timeIntervalSince1970: 1_000_000)
        // 90% + 剩 1h40m（expected 66.7%）→ 阈值与步速同时满足。
        let snapshot = makeLimits(
            sessionWindow: makeSessionWindow(percent: 90, resetAt: t.addingTimeInterval(6000))
        )
        manager.evaluate(snapshot, at: t)
        XCTAssertEqual(client.posted.count, 2)
        let titles = Set(client.posted.map(\.title))
        XCTAssertEqual(titles, [Strings.en.tokenAlertSessionTitle, Strings.en.tokenAlertPaceTitle])
    }

    // MARK: - 无效快照不告警

    func test_notConfiguredDoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let snapshot = makeLimits(
            configured: false,
            sessionWindow: makeSessionWindow(percent: 90, resetAt: Date().addingTimeInterval(3600))
        )
        manager.evaluate(snapshot)
        XCTAssertTrue(client.posted.isEmpty)
    }

    func test_issueSnapshotDoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let snapshot = makeLimits(
            issue: .reauthRequired,
            sessionWindow: makeSessionWindow(percent: 90, resetAt: Date().addingTimeInterval(3600))
        )
        manager.evaluate(snapshot)
        XCTAssertTrue(client.posted.isEmpty)
    }

    func test_staleSnapshotDoesNotPost() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let snapshot = makeLimits(
            stale: true,
            sessionWindow: makeSessionWindow(percent: 90, resetAt: Date().addingTimeInterval(3600))
        )
        manager.evaluate(snapshot)
        XCTAssertTrue(client.posted.isEmpty, "过期回退快照不应触发告警")
    }

    func test_paceRequiresTrustedWindowAndResetData() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client)
        let t = Date(timeIntervalSince1970: 1_000_000)
        // windowSeconds 缺失 → 只触发阈值（90%），不触发步速。
        let untrustedWindow = makeLimits(
            sessionWindow: makeSessionWindow(percent: 90, resetAt: t.addingTimeInterval(6000), windowSeconds: nil)
        )
        manager.evaluate(untrustedWindow, at: t)
        XCTAssertEqual(client.posted.count, 1)
        XCTAssertEqual(client.posted[0].title, Strings.en.tokenAlertSessionTitle)
        // resetAt 缺失 → 无法判步速 → 只触发阈值。
        let noReset = makeLimits(
            sessionWindow: makeSessionWindow(percent: 90, resetAt: nil)
        )
        manager.evaluate(noReset, at: t)
        XCTAssertEqual(client.posted.count, 2)
    }

    // MARK: - 未授权静默降级

    func test_unauthorizedSilentlyDegradesWithoutPosting() {
        let client = FakeTokenUsageNotificationClient()
        let manager = makeManager(client: client, authorized: false)
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 90))
        // 未授权（如非 .app 宿主）：不投递、不崩溃、不上浮。
        manager.evaluate(snapshot, at: thresholdTestPoint)
        manager.evaluate(snapshot, at: thresholdTestPoint.addingTimeInterval(600))
        XCTAssertTrue(client.posted.isEmpty)
    }

    func test_alertPostsAfterPermissionGrantedWithinSameWindow() {
        let client = FakeTokenUsageNotificationClient()
        var authorized = false
        let manager = TokenUsageAlertManager(
            notificationClient: client,
            configuration: { TokenUsageConfiguration() },
            stringsProvider: { .en },
            authorizationProvider: { authorized }
        )
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 90))
        manager.evaluate(snapshot, at: thresholdTestPoint)
        XCTAssertTrue(client.posted.isEmpty, "授权前静默")
        // 用户随后授权：同窗条件仍满足 → 应补发一次并进入防抖。
        authorized = true
        manager.evaluate(snapshot, at: thresholdTestPoint.addingTimeInterval(600))
        XCTAssertEqual(client.posted.count, 1)
        manager.evaluate(snapshot, at: thresholdTestPoint.addingTimeInterval(1200))
        XCTAssertEqual(client.posted.count, 1, "补发后同窗防抖")
    }

    // MARK: - 与 TokenUsageManager 同频接线

    func test_managerRefreshDrivesAlertAndSwitchTakesEffect() async throws {
        let client = FakeTokenUsageNotificationClient()
        let alertManager = makeManager(client: client)
        let fetcher = StubLimitsFetcher(
            provider: .claude,
            results: [.success(makeLimits(
                sessionWindow: makeSessionWindow(percent: 90, resetAt: Date().addingTimeInterval(2000))
            ))]
        )
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.claude: fetcher],
            scheduler: FakeRepeatingScheduler(),
            alerts: alertManager
        )
        manager.start()
        try await waitUntil { client.posted.count == 1 }
        XCTAssertEqual(client.posted[0].title, Strings.en.tokenAlertSessionTitle, "随限额刷新触发阈值告警")
        // 同窗防抖：再次刷新不重复推送。
        manager.refreshNow()
        try await waitUntil { fetcher.callCount == 2 }
        XCTAssertEqual(client.posted.count, 1)
    }

    func test_postDeliveryFailureSwallowedSilentlyAndDebounced() {
        let client = FakeTokenUsageNotificationClient()
        client.postResult = .failure(TestNotificationError.denied)
        let manager = makeManager(client: client)
        let snapshot = makeLimits(sessionWindow: thresholdWindow(percent: 90))
        // 投递失败（如授权被系统回收）不抛错、不上浮；防抖保证同窗不重试刷屏。
        manager.evaluate(snapshot, at: thresholdTestPoint)
        manager.evaluate(snapshot, at: thresholdTestPoint.addingTimeInterval(600))
        XCTAssertEqual(client.posted.count, 1)
    }

    private func makeManager(
        client: FakeTokenUsageNotificationClient,
        configuration: TokenUsageConfiguration = TokenUsageConfiguration(),
        authorized: Bool = true
    ) -> TokenUsageAlertManager {
        let config = configuration
        return TokenUsageAlertManager(
            notificationClient: client,
            configuration: { config },
            stringsProvider: { .en },
            authorizationProvider: { authorized }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TokenUsageAlertManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
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

// MARK: - Test Helpers

private enum TestNotificationError: Error {
    case denied
}

final class FakeTokenUsageNotificationClient: UserNotificationPosting {
    /// 记录每次投递（含失败尝试）；与 MonitorAlertManager 假客户端一致。
    private(set) var posted: [(title: String, body: String)] = []
    /// 可编排的投递结果（未授权/失败降级）。
    var postResult: Result<Void, Error> = .success(())

    func post(title: String, body: String, completion: @escaping (Result<Void, Error>) -> Void) {
        posted.append((title, body))
        completion(postResult)
    }
}
