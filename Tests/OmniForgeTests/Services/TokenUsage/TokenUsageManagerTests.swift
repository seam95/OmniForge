import XCTest
@testable import OmniForge

@MainActor
final class TokenUsageManagerTests: XCTestCase {
    private func makeSnapshot(
        provider: TokenUsageProvider,
        configured: Bool = true,
        issue: LimitError? = nil
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: configured,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: [:],
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: issue
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TokenUsageManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func test_start_populatesLimitsAndUpdateAt() async throws {
        let fetcher = StubLimitsFetcher(
            provider: .claude,
            results: [.success(makeSnapshot(provider: .claude))]
        )
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.claude: fetcher],
            scheduler: FakeRepeatingScheduler()
        )
        manager.start()
        try await waitUntil { manager.limits[.claude] != nil }
        XCTAssertEqual(manager.limits[.claude]?.configured, true)
        XCTAssertNotNil(manager.limitUpdateAt)
        XCTAssertEqual(manager.configuredProviders, [.claude])
        XCTAssertTrue(manager.hasAnyConfiguredProvider)
        XCTAssertEqual(fetcher.callCount, 1)
    }

    func test_start_respectsTimerIntervalFromPreferences() {
        let scheduler = FakeRepeatingScheduler()
        let defaults = makeDefaults()
        var configuration = TokenUsageConfiguration()
        configuration.limitRefreshMinutes = 15
        defaults.set(try! JSONEncoder().encode(configuration), forKey: "OmniForge.tokenUsageConfiguration")
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: defaults),
            fetchers: [.claude: StubLimitsFetcher(provider: .claude, results: [.success(makeSnapshot(provider: .claude))])],
            scheduler: scheduler
        )
        manager.start()
        XCTAssertEqual(scheduler.lastInterval, 900, "按配置间隔调度")
    }

    func test_start_notConfiguredEntryKeepsConfiguredFalse() async throws {
        let fetcher = StubLimitsFetcher(provider: .claude, results: [.success(nil)])
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.claude: fetcher],
            scheduler: FakeRepeatingScheduler()
        )
        manager.start()
        try await waitUntil { manager.limits[.claude] != nil }
        XCTAssertEqual(manager.limits[.claude]?.configured, false)
        XCTAssertFalse(manager.hasAnyConfiguredProvider)
        XCTAssertTrue(manager.configuredProviders.isEmpty)
        XCTAssertNil(manager.limitUpdateAt, "未配置成功抓取不应刷新「更新时间」")
    }

    func test_start_fetchErrorProducesIssueEntry() async throws {
        let fetcher = StubLimitsFetcher(
            provider: .claude,
            results: [.failure(LimitError.reauthRequired)]
        )
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.claude: fetcher],
            scheduler: FakeRepeatingScheduler()
        )
        manager.start()
        try await waitUntil { manager.limits[.claude] != nil }
        XCTAssertEqual(manager.limits[.claude]?.issue, .reauthRequired)
        XCTAssertEqual(manager.limits[.claude]?.configured, true, "错误态保持已配置口径")
        XCTAssertEqual(manager.configuredProviders, [.claude], "已配置但错误也应出现在切换器")
    }

    func test_refreshNow_singleFlightCoalescesConcurrentRefreshes() async throws {
        let gate = AsyncGate()
        let fetcher = StubLimitsFetcher(
            provider: .claude,
            results: [.success(makeSnapshot(provider: .claude))]
        )
        fetcher.gate = gate
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.claude: fetcher],
            scheduler: FakeRepeatingScheduler()
        )
        manager.start()
        // 等第一次进入 in-flight 后立刻再来一次
        try await waitUntil { fetcher.callCount == 1 }
        manager.refreshNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcher.callCount, 1, "in-flight 期间刷新应合并")
        gate.open()
        try await waitUntil { manager.limits[.claude] != nil }
    }

    func test_start_ordersConfiguredProvidersByCatalog() async throws {
        let codex = StubLimitsFetcher(provider: .codex, results: [.success(makeSnapshot(provider: .codex))])
        let claude = StubLimitsFetcher(provider: .claude, results: [.success(makeSnapshot(provider: .claude))])
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.codex: codex, .claude: claude],
            scheduler: FakeRepeatingScheduler()
        )
        manager.start()
        try await waitUntil { manager.limits.count == 2 }
        XCTAssertEqual(manager.configuredProviders, [.claude, .codex], "按 allCases 目录序")
    }

    func test_start_isIdempotentAndStopHalts() async throws {
        let fetcher = StubLimitsFetcher(
            provider: .claude,
            results: [.success(makeSnapshot(provider: .claude))]
        )
        let manager = TokenUsageManager(
            preferences: TokenUsagePreferences(userDefaults: makeDefaults()),
            fetchers: [.claude: fetcher],
            scheduler: FakeRepeatingScheduler()
        )
        manager.start()
        manager.start()
        try await waitUntil { manager.limits[.claude] != nil }
        XCTAssertEqual(fetcher.callCount, 1, "重复 start 不应重复取数")
        manager.stop()
        XCTAssertFalse(manager.isActive)
    }

    // MARK: - 工具

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
