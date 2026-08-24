import Foundation
import XCTest
@testable import OmniForge

/// DeepSeek 余额管理器：定时间隔/单飞、失败降级（stale 保留旧值）、
/// 密钥配置生命周期与低余额跨阈值单次通知（恢复/设置变化后复位）。
@MainActor
final class DeepSeekBalanceManagerTests: XCTestCase {
    private struct Harness {
        let manager: DeepSeekBalanceManager
        let preferences: TokenUsagePreferences
        let keyStore: FakeDeepSeekKeyStore
        let fetcher: FakeDeepSeekBalanceFetcher
        let scheduler: FakeRepeatingScheduler
        let notification: FakeTokenUsageNotificationClient
        let authorization: AuthorizationStub
    }

    /// 可翻转的授权桩（模拟「未授权 → 用户授权」）。
    private final class AuthorizationStub {
        var allowed = true
    }

    // MARK: - 生命周期与取数

    func test_startWithConfiguredKeyFetchesAndPublishesSnapshot() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse(cny: "18.22")))
        harness.manager.start()
        await drain()

        XCTAssertEqual(harness.manager.apiKeyConfigured, true)
        XCTAssertEqual(harness.manager.showingBalanceCard, true)
        let snapshot = try XCTUnwrap(harness.manager.snapshot)
        XCTAssertEqual(snapshot.infos.first?.totalBalance, Decimal(string: "18.22"))
        XCTAssertEqual(snapshot.issue, nil)
        XCTAssertEqual(snapshot.stale, false)
        XCTAssertEqual(harness.fetcher.callCount, 1)
    }

    func test_startWithoutKeyStaysUnconfiguredAndHidden() async throws {
        let harness = makeHarness(key: nil)
        harness.manager.start()
        await drain()

        XCTAssertEqual(harness.manager.apiKeyConfigured, false)
        XCTAssertEqual(harness.manager.showingBalanceCard, false)
        XCTAssertNil(harness.manager.snapshot)
        XCTAssertEqual(harness.fetcher.callCount, 0, "未配置 → 零请求")
    }

    func test_saveAPIKeyWritesKeychainAndRefreshesImmediately() async throws {
        let harness = makeHarness(key: nil, fetcher: fetcher(responding: balanceResponse()))
        harness.manager.start()
        await drain()
        XCTAssertEqual(harness.fetcher.callCount, 0)

        try harness.manager.saveAPIKey("sk-new-key")
        await drain()

        XCTAssertEqual(harness.keyStore.storedKey, "sk-new-key")
        XCTAssertEqual(harness.keyStore.writeCount, 1)
        XCTAssertEqual(harness.manager.apiKeyConfigured, true)
        XCTAssertEqual(harness.fetcher.callCount, 1, "保存后立即拉取")
    }

    func test_saveAPIKeyRejectsBlank() throws {
        let harness = makeHarness()
        XCTAssertThrowsError(try harness.manager.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? DeepSeekBalanceError, .emptyAPIKey)
        }
        XCTAssertEqual(harness.keyStore.writeCount, 0)
    }

    func test_deleteAPIKeyClearsSnapshotAndFlag() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse()))
        harness.manager.start()
        await drain()
        XCTAssertNotNil(harness.manager.snapshot)

        try harness.manager.deleteAPIKey()
        XCTAssertEqual(harness.keyStore.deleteCount, 1)
        XCTAssertEqual(harness.manager.apiKeyConfigured, false)
        XCTAssertNil(harness.manager.snapshot)
    }

    // MARK: - 失败降级

    func test_networkErrorKeepsLastSnapshotAndMarksStale() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .success(balanceResponse(cny: "18.22")),
            .failure(LimitError.network("offline")),
        ]
        let harness = makeHarness(fetcher: fetcher)
        harness.manager.start()
        await drain()
        let first = try XCTUnwrap(harness.manager.snapshot)
        let firstCapturedAt = first.capturedAt

        harness.manager.refreshNow()
        await drain()

        let snapshot = try XCTUnwrap(harness.manager.snapshot)
        XCTAssertEqual(snapshot.stale, true, "失败 → stale")
        XCTAssertEqual(snapshot.issue, .network("offline"))
        XCTAssertEqual(snapshot.infos.first?.totalBalance, Decimal(string: "18.22"), "保留旧值")
        XCTAssertEqual(snapshot.capturedAt, firstCapturedAt, "capturedAt 不动")
    }

    func test_reauthRequiredSetsIssueAndKeepsLastValues() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .success(balanceResponse(cny: "18.22")),
            .failure(LimitError.reauthRequired),
        ]
        let harness = makeHarness(fetcher: fetcher)
        harness.manager.start()
        await drain()
        harness.manager.refreshNow()
        await drain()

        let snapshot = try XCTUnwrap(harness.manager.snapshot)
        XCTAssertEqual(snapshot.issue, .reauthRequired)
        XCTAssertEqual(snapshot.infos.first?.totalBalance, Decimal(string: "18.22"))
    }

    func test_rateLimitedSetsIssue() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .failure(LimitError.rateLimited(retryAt: Date(timeIntervalSince1970: 1_800_000_360))),
        ]
        let harness = makeHarness(fetcher: fetcher)
        harness.manager.start()
        await drain()

        let snapshot = try XCTUnwrap(harness.manager.snapshot)
        XCTAssertEqual(snapshot.issue, .rateLimited(retryAt: Date(timeIntervalSince1970: 1_800_000_360)))
        XCTAssertEqual(snapshot.infos.count, 0, "从未成功 → 空数据")
        XCTAssertEqual(snapshot.stale, false)
    }

    func test_firstFetchErrorPublishesEmptyInfosWithIssue() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: [:])) // 空字典 → 解码失败
        harness.manager.start()
        await drain()

        let snapshot = try XCTUnwrap(harness.manager.snapshot)
        XCTAssertEqual(snapshot.issue, .decoding("balance_infos missing"))
        XCTAssertEqual(snapshot.infos.count, 0)
    }

    // MARK: - 单飞与定时

    func test_singleFlight_doesNotDuplicateConcurrentRefreshNow() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse(cny: "18.22")))
        harness.manager.start()
        harness.manager.refreshNow() // 同步连续触发：第二次必须被单飞合并
        await drain()

        XCTAssertEqual(harness.fetcher.callCount, 1, "并发刷新合并为一次")
        XCTAssertNotNil(harness.manager.snapshot)
    }

    func test_timerReschedulesWhenRefreshMinutesChange() throws {
        let harness = makeHarness()
        harness.manager.start()
        XCTAssertEqual(harness.scheduler.lastInterval, 300, "默认 5 分钟")

        try harness.preferences.setDeepSeekRefreshMinutes(15)
        XCTAssertEqual(harness.scheduler.lastInterval, 900, "配置变化重排")
    }

    // MARK: - 低余额告警

    func test_lowBalanceFiresOnceBelowThreshold() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse(cny: "0.50")))
        harness.manager.start()
        await drain()
        harness.manager.refreshNow()
        await drain()

        XCTAssertEqual(harness.notification.posted.count, 1, "跨阈值只报一次")
        let posted = harness.notification.posted[0]
        XCTAssertEqual(posted.title, L10n().s.deepSeekAlertTitle)
        XCTAssertTrue(posted.body.contains("¥0.50"), "通知含余额：\(posted.body)")
    }

    func test_lowBalanceNotFiredAboveThreshold() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse(cny: "18.22")))
        harness.manager.start()
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 0)
    }

    func test_lowBalanceRearmsAfterRecoveryAndFiresOnRedrop() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .success(balanceResponse(cny: "0.50")),
            .success(balanceResponse(cny: "10.00")),
            .success(balanceResponse(cny: "0.30")),
        ]
        let harness = makeHarness(fetcher: fetcher)
        harness.manager.start()
        await drain()
        harness.manager.refreshNow()
        await drain()
        harness.manager.refreshNow()
        await drain()

        XCTAssertEqual(harness.notification.posted.count, 2, "恢复后重置，再次跌破可再报")
    }

    func test_lowBalanceNotPostedForIssueOrStaleSnapshots() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .success(balanceResponse(cny: "0.50")),
            .failure(LimitError.network("offline")),
            .success(balanceResponse(cny: "0.50")),
        ]
        let harness = makeHarness(fetcher: fetcher)
        harness.manager.start()
        await drain()
        harness.manager.refreshNow()
        await drain()
        harness.manager.refreshNow()
        await drain()

        XCTAssertEqual(harness.notification.posted.count, 1, "失败快照不判定；同阈值只报一次")
    }

    func test_lowBalanceDisabledDoesNotPost() async throws {
        let harness = makeHarness(
            fetcher: fetcher(responding: balanceResponse(cny: "0.50")),
            alertEnabled: false
        )
        harness.manager.start()
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 0)
    }

    func test_lowBalanceUnauthorizedSilentlyDegradesThenPostsWhenGranted() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse(cny: "0.50")), authorized: false)
        harness.manager.start()
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 0, "未授权静默")

        harness.authorization.allowed = true
        harness.manager.refreshNow()
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 1, "授权后补发一次")
    }

    func test_postDeliveryFailureSwallowedAndNotRetriedSameTick() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse(cny: "0.50")))
        harness.notification.postResult = .failure(URLError(.notConnectedToInternet))
        harness.manager.start()
        await drain()
        harness.manager.refreshNow()
        await drain()

        XCTAssertEqual(harness.notification.posted.count, 1, "投递失败被吞掉且当轮不重试")
    }

    func test_alertReArmsWhenThresholdRaised() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .success(balanceResponse(cny: "3.00")),
            .success(balanceResponse(cny: "3.00")),
        ]
        let harness = makeHarness(fetcher: fetcher, threshold: 1.0)
        harness.manager.start()
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 0, "3.00 > 阈值 1 不报")

        try harness.preferences.setDeepSeekThreshold(5.0)
        harness.manager.refreshNow()
        await drain()
        // 阈值提到 5 后 3.00 ≤ 5，设置边沿已复位 → 再报一次
        XCTAssertEqual(harness.notification.posted.count, 1)
    }

    func test_deleteAPIKeyResetsArmedState() async throws {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [
            .success(balanceResponse(cny: "0.50")),
            .success(balanceResponse(cny: "0.50")),
        ]
        let harness = makeHarness(fetcher: fetcher)
        harness.manager.start()
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 1)

        try harness.manager.deleteAPIKey()
        XCTAssertEqual(harness.notification.posted.count, 1)
        try harness.manager.saveAPIKey("sk-again")
        await drain()
        XCTAssertEqual(harness.notification.posted.count, 2, "删除后重存 → 重新武装")
    }

    // MARK: - 请求细节

    func test_requestHeadersContainBearerKey() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse()))
        harness.manager.start()
        await drain()

        XCTAssertEqual(harness.fetcher.lastHeaders?["Authorization"], "Bearer sk-test-123")
        XCTAssertEqual(harness.fetcher.lastHeaders?["Accept"], "application/json")
    }

    func test_endpointURLIsOfficialBalanceEndpoint() async throws {
        let harness = makeHarness(fetcher: fetcher(responding: balanceResponse()))
        harness.manager.start()
        await drain()

        XCTAssertEqual(harness.fetcher.lastURL, DeepSeekBalanceManager.endpoint)
    }

    // MARK: - 工具

    private func makeHarness(
        key: String? = "sk-test-123",
        fetcher: FakeDeepSeekBalanceFetcher = FakeDeepSeekBalanceFetcher(),
        alertEnabled: Bool = true,
        threshold: Double = 1.0,
        authorized: Bool = true
    ) -> Harness {
        let suite = "DeepSeekBalanceManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let preferences = TokenUsagePreferences(userDefaults: defaults)
        if !alertEnabled {
            preferences.setDeepSeekLowBalanceAlertEnabled(false)
        }
        if threshold != 1.0 {
            preferences.setDeepSeekThreshold(threshold)
        }

        let keyStore = FakeDeepSeekKeyStore()
        keyStore.storedKey = key
        let notification = FakeTokenUsageNotificationClient()
        let authorization = AuthorizationStub()
        authorization.allowed = authorized
        let scheduler = FakeRepeatingScheduler()
        let manager = DeepSeekBalanceManager(
            preferences: preferences,
            keyStore: keyStore,
            fetcher: fetcher,
            scheduler: scheduler,
            notificationClient: notification,
            authorizationProvider: { authorization.allowed },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return Harness(
            manager: manager,
            preferences: preferences,
            keyStore: keyStore,
            fetcher: fetcher,
            scheduler: scheduler,
            notification: notification,
            authorization: authorization
        )
    }

    private func fetcher(responding body: [String: Any]) -> FakeDeepSeekBalanceFetcher {
        let fetcher = FakeDeepSeekBalanceFetcher()
        fetcher.results = [.success(body)]
        return fetcher
    }

    private func balanceResponse(cny: String = "110.00", isAvailable: Bool = true) -> [String: Any] {
        [
            "is_available": isAvailable,
            "balance_infos": [
                ["currency": "CNY", "total_balance": cny, "granted_balance": "10.00", "topped_up_balance": "100.00"],
            ],
        ]
    }

    /// 让主线程队列上的异步取数任务跑完。
    private func drain() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}
