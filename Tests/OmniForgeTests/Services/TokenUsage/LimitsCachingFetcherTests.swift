import XCTest
@testable import OmniForge

/// LimitsCachingFetcher：内存新鲜命中 / force 穿透 / 429 冷却 / last-good 回退 / reauth 短路。
final class LimitsCachingFetcherTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(
        cache: FakeLimitsCache,
        results: [Result<ProviderUsageLimits?, Error>]
    ) -> (fetcher: LimitsCachingFetcher, inner: StubLimitsFetcher) {
        let inner = StubLimitsFetcher(provider: .claude, results: results)
        let fetcher = LimitsCachingFetcher(inner: inner, cache: cache, now: { self.now })
        return (fetcher, inner)
    }

    private func snapshot(
        windows: [LimitWindowKind: UsageWindow] = [:],
        capturedAt: Date? = nil,
        issue: LimitError? = nil,
        stale: Bool = false
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: .claude,
            configured: true,
            subscriptionStatus: .active,
            planLabel: "Pro",
            windows: windows,
            confidence: .official,
            capturedAt: capturedAt ?? now,
            stale: stale,
            issue: issue
        )
    }

    private func window(resetAt: Date? = nil) -> UsageWindow {
        UsageWindow(
            usedPercent: 30,
            resetAt: resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: 18000
        )
    }

    // MARK: 内存新鲜命中（软刷新）

    func test_freshMemoryServedWithoutUpstreamCall() async throws {
        let cache = FakeLimitsCache()
        cache.memorySnapshotResult = snapshot(windows: [.session: window()])
        let (fetcher, inner) = make(cache: cache, results: [.failure(LimitError.network("should not be hit"))])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result, cache.memorySnapshotResult)
        XCTAssertEqual(inner.callCount, 0, "内存新鲜时不打上游")
    }

    func test_forcePenetratesFreshMemory() async throws {
        let cache = FakeLimitsCache()
        cache.memorySnapshotResult = snapshot(windows: [.session: window()])
        let fetched = snapshot(windows: [.session: window(resetAt: now.addingTimeInterval(3600))])
        let (fetcher, inner) = make(cache: cache, results: [.success(fetched)])
        let result = try await fetcher.fetchLimits(force: true)
        XCTAssertEqual(inner.callCount, 1, "force 穿透内存缓存")
        XCTAssertEqual(result, fetched)
    }

    // MARK: 429 冷却

    func test_cooldown_skipsUpstreamEvenWhenForced() async throws {
        let cache = FakeLimitsCache()
        cache.cooldownResult = now.addingTimeInterval(300)
        let (fetcher, inner) = make(cache: cache, results: [.failure(LimitError.network("should not be hit"))])
        let result = try await fetcher.fetchLimits(force: true)
        XCTAssertEqual(inner.callCount, 0, "冷却期跳过上游（force 也不能穿透）")
        assertRateLimited(result?.issue, retryAt: cache.cooldownResult!)
        XCTAssertEqual(result?.stale, true, "冷却期缓存数据标 stale")
    }

    func test_cooldown_returnsLastGoodWindowsWithRateLimitIssue() async throws {
        let cache = FakeLimitsCache()
        cache.cooldownResult = now.addingTimeInterval(240)
        let lastGood = snapshot(windows: [.session: window()], capturedAt: now.addingTimeInterval(-600))
        cache.lastGoodSnapshotResult = lastGood
        let (fetcher, inner) = make(cache: cache, results: [.failure(LimitError.network("should not be hit"))])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(inner.callCount, 0)
        assertRateLimited(result?.issue, retryAt: cache.cooldownResult!)
        XCTAssertEqual(result?.windows, lastGood.windows, "冷却期展示 last-good 窗口")
        XCTAssertEqual(result?.capturedAt, lastGood.capturedAt)
        XCTAssertEqual(result?.stale, true, "冷却期缓存数据标 stale")
    }

    func test_cooldown_notHonoredOnceExpired() async throws {
        let cache = FakeLimitsCache()
        cache.cooldownResult = now.addingTimeInterval(-10)
        let fetched = snapshot()
        let (fetcher, inner) = make(cache: cache, results: [.success(fetched)])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(inner.callCount, 1)
        XCTAssertEqual(result, fetched)
    }

    func test_429Failure_persistsCooldownAndFallsBack() async throws {
        let cache = FakeLimitsCache()
        let lastGood = snapshot(windows: [.session: window()], capturedAt: now.addingTimeInterval(-600))
        cache.lastGoodSnapshotResult = lastGood
        let retryAt = now.addingTimeInterval(300)
        let (fetcher, inner) = make(cache: cache, results: [.failure(LimitError.rateLimited(retryAt: retryAt))])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(cache.storedRateLimits[.claude], [retryAt], "429 写冷却")
        XCTAssertEqual(result?.issue, .rateLimited(retryAt: retryAt))
        XCTAssertEqual(result?.stale, true)
        XCTAssertEqual(result?.windows, lastGood.windows)
        XCTAssertEqual(inner.callCount, 1)
    }

    // MARK: 失败回退

    func test_networkFailure_fallsBackToLastGoodMarkedStale() async throws {
        let cache = FakeLimitsCache()
        let lastGood = snapshot(windows: [.session: window()], capturedAt: now.addingTimeInterval(-600))
        cache.lastGoodSnapshotResult = lastGood
        let (fetcher, _) = make(cache: cache, results: [.failure(LimitError.network("offline"))])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.stale, true, "回退快照标 stale")
        XCTAssertEqual(result?.issue, .network("offline"))
        XCTAssertEqual(result?.windows, lastGood.windows, "显示上一次成功快照")
        XCTAssertEqual(result?.capturedAt, lastGood.capturedAt, "沿用上次成功时间（来源标注对齐缓存）")
    }

    func test_networkFailureWithoutLastGood_returnsErrorEntry() async throws {
        let cache = FakeLimitsCache()
        let (fetcher, _) = make(cache: cache, results: [.failure(LimitError.network("offline"))])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.issue, .network("offline"))
        XCTAssertTrue(result?.windows.isEmpty ?? false)
    }

    // MARK: 带 issue 快照（非成功结果，如 Antigravity 进程不在）

    func test_issueSnapshot_fallsBackToLastGoodWithoutStoring() async throws {
        let cache = FakeLimitsCache()
        let lastGood = snapshot(windows: [.session: window()], capturedAt: now.addingTimeInterval(-600))
        cache.lastGoodSnapshotResult = lastGood
        let issueSnapshot = snapshot(issue: .network("not running"))
        let (fetcher, _) = make(cache: cache, results: [.success(issueSnapshot)])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.issue, .network("not running"), "issue 保留")
        XCTAssertEqual(result?.stale, true, "回退快照标 stale")
        XCTAssertEqual(result?.windows, lastGood.windows, "显示上一次成功快照")
        XCTAssertEqual(cache.storedSuccess[.claude] ?? [], [], "错误快照不得作为成功落缓存")
        XCTAssertFalse(cache.clearedCooldowns.contains(.claude), "错误快照不解除冷却")
    }

    func test_issueSnapshotWithoutLastGood_returnsErrorEntry() async throws {
        let cache = FakeLimitsCache()
        let (fetcher, _) = make(cache: cache, results: [.success(snapshot(issue: .network("not running")))])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.issue, .network("not running"))
        XCTAssertTrue(result?.windows.isEmpty ?? false)
        XCTAssertEqual(cache.storedSuccess[.claude] ?? [], [], "错误快照不得作为成功落缓存")
    }

    func test_success_storesCacheAndClearsCooldown() async throws {
        let cache = FakeLimitsCache()
        let fetched = snapshot(windows: [.session: window()])
        let (fetcher, _) = make(cache: cache, results: [.success(fetched)])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result, fetched)
        XCTAssertEqual(cache.storedSuccess[.claude], [fetched], "成功快照落缓存")
        XCTAssertTrue(cache.clearedCooldowns.contains(.claude), "成功后解除冷却")
        XCTAssertFalse(cache.clearedProviders.contains(.claude))
    }

    // MARK: reauth 短路 / 未配置

    func test_reauthFailure_shortCircuitsWithoutFallback() async throws {
        let cache = FakeLimitsCache()
        cache.lastGoodSnapshotResult = snapshot(windows: [.session: window()])
        let (fetcher, inner) = make(cache: cache, results: [.failure(LimitError.reauthRequired)])
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("reauth 应回抛")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        }
        XCTAssertEqual(inner.callCount, 1)
        XCTAssertEqual(cache.storedRateLimits[.claude] ?? [], [], "reauth 不写冷却")
        XCTAssertEqual(cache.storedSuccess[.claude] ?? [], [], "reauth 不覆盖缓存")
    }

    func test_notConfigured_clearsCacheAndReturnsNil() async throws {
        let cache = FakeLimitsCache()
        let (fetcher, _) = make(cache: cache, results: [.success(nil)])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(cache.clearedProviders.contains(.claude), "未配置时清空该 provider 缓存")
    }

    // MARK: - 工具

    private func assertRateLimited(_ issue: LimitError?, retryAt: Date) {
        guard case .rateLimited(let found)? = issue else {
            XCTFail("应为 rateLimited 错误")
            return
        }
        XCTAssertEqual(found, retryAt)
    }
}
