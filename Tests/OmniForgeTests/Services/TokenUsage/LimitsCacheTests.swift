import XCTest
@testable import OmniForge

// MARK: - 纯策略：TTL + reset 边界提前过期 + 过期窗口丢弃（参考 06）

final class LimitsCachePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func window(resetAt: Date?) -> UsageWindow {
        UsageWindow(
            usedPercent: 20,
            resetAt: resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: 18000
        )
    }

    func test_expirationDate_usesTTLWhenNoFutureReset() {
        let expiry = LimitsCachePolicy.expirationDate(now: now, ttl: 300, windows: [:])
        XCTAssertEqual(expiry, now.addingTimeInterval(300))
    }

    func test_expirationDate_shiftsToNearestFutureResetBeforeTTL() {
        let windows: [LimitWindowKind: UsageWindow] = [
            .session: window(resetAt: now.addingTimeInterval(60)),
            .weekly: window(resetAt: now.addingTimeInterval(3600)),
        ]
        let expiry = LimitsCachePolicy.expirationDate(now: now, ttl: 300, windows: windows)
        XCTAssertEqual(expiry, now.addingTimeInterval(60), "任一窗口 reset 边界使缓存提前过期")
    }

    func test_expirationDate_ignoresPastResets() {
        let windows: [LimitWindowKind: UsageWindow] = [
            .session: window(resetAt: now.addingTimeInterval(-60)),
        ]
        let expiry = LimitsCachePolicy.expirationDate(now: now, ttl: 300, windows: windows)
        XCTAssertEqual(expiry, now.addingTimeInterval(300), "已过的 reset 不影响过期点")
    }

    func test_expirationDate_hasMinFloorWhenResetIsImminent() {
        let windows: [LimitWindowKind: UsageWindow] = [
            .session: window(resetAt: now.addingTimeInterval(2)),
        ]
        let expiry = LimitsCachePolicy.expirationDate(now: now, ttl: 300, windows: windows)
        XCTAssertEqual(expiry, now.addingTimeInterval(5), "下限 5 秒，防 reset 就在此刻导致每次全量拉取")
    }

    func test_discardingExpiredWindows_dropsPastKeepsFutureAndUndated() {
        let windows: [LimitWindowKind: UsageWindow] = [
            .session: window(resetAt: now.addingTimeInterval(-1)),
            .weekly: window(resetAt: now.addingTimeInterval(60)),
            .credits: window(resetAt: nil),
        ]
        let kept = LimitsCachePolicy.discardingExpiredWindows(windows, at: now)
        XCTAssertNil(kept[.session], "已过期 reset 的窗口应被丢弃")
        XCTAssertNotNil(kept[.weekly])
        XCTAssertNotNil(kept[.credits], "无 reset 的窗口保留")
    }
}

// MARK: - 缓存存储：内存 TTL / 磁盘 last-good / 429 冷却（tmp+rename+0600）

final class TokenUsageLimitsCacheTests: XCTestCase {
    private var tempRoot: URL!
    private var current: Date!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenUsageLimitsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        current = Date(timeIntervalSince1970: 1_700_000_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeCache() -> TokenUsageLimitsCache {
        TokenUsageLimitsCache(applicationSupportRoot: tempRoot, now: { self.current })
    }

    private func window(resetAt: Date?) -> UsageWindow {
        UsageWindow(
            usedPercent: 20,
            resetAt: resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: 18000
        )
    }

    private func snapshot(
        provider: TokenUsageProvider = .claude,
        windows: [LimitWindowKind: UsageWindow] = [:],
        capturedAt: Date? = nil
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: "Pro",
            windows: windows,
            confidence: .official,
            capturedAt: capturedAt ?? current,
            stale: false,
            issue: nil
        )
    }

    // MARK: 内存 TTL

    func test_memorySnapshot_expiresAtTTL() {
        let cache = makeCache()
        cache.storeSuccess(snapshot())
        // 断言对齐 LimitsCachePolicy.defaultTTL（120s），避免 TTL 调整时再断
        current = current.addingTimeInterval(LimitsCachePolicy.defaultTTL - 1)
        XCTAssertNotNil(cache.memorySnapshot(for: .claude), "TTL 内仍新鲜")
        current = current.addingTimeInterval(2)
        XCTAssertNil(cache.memorySnapshot(for: .claude), "TTL 过后失效")
    }

    func test_memorySnapshot_expiresAtResetBoundaryBeforeTTL() {
        let cache = makeCache()
        cache.storeSuccess(snapshot(windows: [.session: window(resetAt: current.addingTimeInterval(60))]))
        current = current.addingTimeInterval(61)
        XCTAssertNil(cache.memorySnapshot(for: .claude), "reset 边界提前过期（早于 TTL）")
    }

    func test_memorySnapshot_minFloorServesImminentResetWindow() {
        let cache = makeCache()
        cache.storeSuccess(snapshot(windows: [.session: window(resetAt: current.addingTimeInterval(2))]))
        current = current.addingTimeInterval(4)
        XCTAssertNotNil(cache.memorySnapshot(for: .claude), "下限 5 秒内仍新鲜")
        current = current.addingTimeInterval(2)
        XCTAssertNil(cache.memorySnapshot(for: .claude))
    }

    // MARK: last-good 快照

    func test_lastGoodSnapshot_prefersMemoryEvenAfterTTLExpiry() {
        let cache = makeCache()
        cache.storeSuccess(snapshot(windows: [.session: window(resetAt: current.addingTimeInterval(3600))]))
        current = current.addingTimeInterval(400)
        XCTAssertNil(cache.memorySnapshot(for: .claude))
        let last = cache.lastGoodSnapshot(for: .claude)
        XCTAssertNotNil(last, "失败回退仍可用刚过期的内存快照")
        XCTAssertNotNil(last?.windows[.session])
    }

    func test_lastGoodSnapshot_fallsBackToDiskAndDropsExpiredWindows() {
        let captured = current.addingTimeInterval(-600)
        let cache = makeCache()
        cache.storeSuccess(snapshot(
            windows: [
                .session: window(resetAt: current.addingTimeInterval(3600)),
                .weekly: window(resetAt: current.addingTimeInterval(-60)),
            ],
            capturedAt: captured
        ))
        current = current.addingTimeInterval(120)
        // 新实例模拟进程重启：内存清空，仅剩磁盘 last-good。
        let reloaded = TokenUsageLimitsCache(applicationSupportRoot: tempRoot, now: { self.current })
        let last = reloaded.lastGoodSnapshot(for: .claude)
        XCTAssertNotNil(last)
        XCTAssertNotNil(last?.windows[.session], "尚未 reset 的窗口保留")
        XCTAssertNil(last?.windows[.weekly], "已过期 reset 的窗口在读取时丢弃")
        XCTAssertEqual(last?.capturedAt, captured, "沿用上次成功时间")
    }

    func test_lastGoodSnapshot_returnsNilWhenAllWindowsExpired() {
        let cache = makeCache()
        cache.storeSuccess(snapshot(windows: [.session: window(resetAt: current.addingTimeInterval(30))]))
        current = current.addingTimeInterval(60)
        let reloaded = TokenUsageLimitsCache(applicationSupportRoot: tempRoot, now: { self.current })
        XCTAssertNil(reloaded.lastGoodSnapshot(for: .claude), "窗口全过期 → 视为无 last-good")
    }

    func test_storeNotConfigured_clearsMemoryAndDisk() {
        let cache = makeCache()
        cache.storeSuccess(snapshot())
        cache.storeNotConfigured(.claude)
        XCTAssertNil(cache.memorySnapshot(for: .claude))
        XCTAssertNil(cache.lastGoodSnapshot(for: .claude))
        let reloaded = TokenUsageLimitsCache(applicationSupportRoot: tempRoot, now: { self.current })
        XCTAssertNil(reloaded.lastGoodSnapshot(for: .claude), "磁盘 last-good 同时清除")
    }

    // MARK: 429 冷却持久化

    func test_cooldown_persistsAndExpires() {
        let cache = makeCache()
        let retryAt = current.addingTimeInterval(300)
        cache.storeRateLimit(for: .claude, retryAt: retryAt)
        XCTAssertEqual(cache.cooldown(for: .claude), retryAt)
        current = current.addingTimeInterval(301)
        XCTAssertNil(cache.cooldown(for: .claude), "冷却到期后视为无冷却")
    }

    func test_cooldown_survivesRestart() {
        let cache = makeCache()
        let retryAt = current.addingTimeInterval(300)
        cache.storeRateLimit(for: .claude, retryAt: retryAt)
        let reloaded = TokenUsageLimitsCache(applicationSupportRoot: tempRoot, now: { self.current })
        XCTAssertEqual(reloaded.cooldown(for: .claude), retryAt, "进程重启后仍遵守冷却")
    }

    func test_cooldown_clampedToOneHour() {
        let cache = makeCache()
        cache.storeRateLimit(for: .claude, retryAt: current.addingTimeInterval(7200))
        XCTAssertEqual(cache.cooldown(for: .claude), current.addingTimeInterval(3600), "冷却上限 1 小时")
    }

    func test_storeSuccess_clearsPersistedCooldown() {
        let cache = makeCache()
        let retryAt = current.addingTimeInterval(300)
        cache.storeRateLimit(for: .claude, retryAt: retryAt)
        XCTAssertNotNil(cache.cooldown(for: .claude))
        cache.storeSuccess(snapshot())
        XCTAssertNil(cache.cooldown(for: .claude), "成功取数后冷却解除")
    }

    func test_clearCooldown_removesPersistedCooling() {
        let cache = makeCache()
        cache.storeRateLimit(for: .claude, retryAt: current.addingTimeInterval(300))
        cache.clearCooldown(for: .claude)
        XCTAssertNil(cache.cooldown(for: .claude))
        let reloaded = TokenUsageLimitsCache(applicationSupportRoot: tempRoot, now: { self.current })
        XCTAssertNil(reloaded.cooldown(for: .claude))
    }

    // MARK: 文件权限

    func test_cacheFilesWrittenWith0600Permissions() throws {
        let cache = makeCache()
        cache.storeSuccess(snapshot())
        cache.storeRateLimit(for: .claude, retryAt: current.addingTimeInterval(300))
        for name in ["claude-usage-limits-last-good.json", "claude-usage-rate-limit.json"] {
            let url = tempRoot.appendingPathComponent("TokenUsage/\(name)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缓存文件应存在：\(name)")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(permissions, 0o600, "缓存文件应为 0600：\(name)")
        }
    }
}
