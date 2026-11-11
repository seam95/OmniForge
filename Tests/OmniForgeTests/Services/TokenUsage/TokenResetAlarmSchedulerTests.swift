import XCTest
@testable import OmniForge

/// 额度重置静默闹钟 — 布防 / 校准 / 触发 / 漂移重设 / 降级保留 / 持久化恢复。
@MainActor
final class TokenResetAlarmSchedulerTests: XCTestCase {

    private var now: Date = Date(timeIntervalSince1970: 1_704_800_000)
    private var suite = ""
    /// 同一实例复用：同 suite 的不同 UserDefaults 实例间写入不立即可见。
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "TokenResetAlarmSchedulerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeScheduler(scheduling: FakeOneShotScheduler) -> TokenResetAlarmScheduler {
        TokenResetAlarmScheduler(
            scheduling: scheduling,
            defaults: defaults,
            stringsProvider: { .en },
            now: { [self] in now }
        )
    }

    /// 单窗口快照（resetAt 相对 now 偏移秒）。
    /// issue/stale 态仍携带 windows — 对齐 LimitsCachingFetcher 的 last-good 回退形态。
    private func makeLimits(
        provider: TokenUsageProvider = .codex,
        usedPercent: Double = 90,
        resetOffset: TimeInterval,
        issue: LimitError? = nil,
        stale: Bool = false
    ) -> [TokenUsageProvider: ProviderUsageLimits] {
        let window = UsageWindow(
            usedPercent: usedPercent,
            resetAt: now.addingTimeInterval(resetOffset)
        )
        return [
            provider: ProviderUsageLimits(
                provider: provider,
                configured: true,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: [.weekly: window],
                confidence: .official,
                capturedAt: now,
                stale: stale,
                issue: issue
            )
        ]
    }

    // MARK: - 布防

    func test_sync_armsCalibrateAndFireAlarms() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)

        scheduler.sync(limits: makeLimits(resetOffset: 3600))

        XCTAssertEqual(
            scheduling.activeDeadlines,
            [now.addingTimeInterval(3540), now.addingTimeInterval(3600)],
            "resetAt − 60s 校准点 + resetAt 触发点"
        )
    }

    func test_sync_resetAtWithinLead_skipsCalibrateAlarm() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)

        // resetAt 距 now 不足 60s：校准点已过期，只布触发点。
        scheduler.sync(limits: makeLimits(resetOffset: 30))

        XCTAssertEqual(scheduling.activeDeadlines, [now.addingTimeInterval(30)])
    }

    func test_sync_missingResetAt_noAlarm() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)
        let window = UsageWindow(usedPercent: 90, resetAt: nil)

        scheduler.sync(limits: [
            .codex: ProviderUsageLimits(
                provider: .codex,
                configured: true,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: [.weekly: window],
                confidence: .official,
                capturedAt: now,
                stale: false,
                issue: nil
            )
        ])

        XCTAssertTrue(scheduling.activeDeadlines.isEmpty, "无重置时刻的窗口不建闹钟")
    }

    // MARK: - 漂移

    func test_sync_driftBeyondTolerance_rearms() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)

        scheduler.sync(limits: makeLimits(resetOffset: 3600))
        scheduler.sync(limits: makeLimits(resetOffset: 3720))

        XCTAssertEqual(
            scheduling.activeDeadlines,
            [now.addingTimeInterval(3660), now.addingTimeInterval(3720)],
            "resetAt 前进超过容差 → 按新时刻重设"
        )
    }

    func test_sync_smallDrift_keepsAlarmButUpdatesPercent() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)
        var fired: TokenResetAlarmScheduler.AlarmRecord?
        scheduler.onFire = { fired = $0 }

        scheduler.sync(limits: makeLimits(usedPercent: 90, resetOffset: 3600))
        // 抖动 30s（< 60s 容差）：闹钟保持原时刻，百分比跟进。
        scheduler.sync(limits: makeLimits(usedPercent: 40, resetOffset: 3630))
        XCTAssertEqual(
            scheduling.activeDeadlines,
            [now.addingTimeInterval(3540), now.addingTimeInterval(3600)],
            "小抖动不重设闹钟"
        )

        scheduling.fire(through: now.addingTimeInterval(3600))
        XCTAssertEqual(fired?.usedPercent, 40, "触发记录携带最新百分比")
    }

    // MARK: - 降级保留 / 消失移除

    func test_sync_issueFallbackKeepsExistingAlarm() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)

        scheduler.sync(limits: makeLimits(resetOffset: 3600))
        // 校准拉取失败回退：issue 态 + 空 windows（无 last-good 场景）— 已配置口径保留闹钟。
        scheduler.sync(limits: makeLimits(resetOffset: 3600, issue: .network("offline"), stale: true))
        XCTAssertEqual(scheduling.activeDeadlines.count, 2, "失败回退不清掉既有闹钟")

        // 窗口真正消失（未配置）→ 移除。
        scheduler.sync(limits: [:])
        XCTAssertTrue(scheduling.activeDeadlines.isEmpty)
    }

    func test_sync_notConfigured_removesAlarm() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)

        scheduler.sync(limits: makeLimits(resetOffset: 3600))
        let window = UsageWindow(usedPercent: 90, resetAt: now.addingTimeInterval(3600))
        scheduler.sync(limits: [
            .codex: ProviderUsageLimits(
                provider: .codex,
                configured: false,
                subscriptionStatus: .unknown,
                planLabel: nil,
                windows: [.weekly: window],
                confidence: .official,
                capturedAt: now,
                stale: false,
                issue: nil
            )
        ])

        XCTAssertTrue(scheduling.activeDeadlines.isEmpty, "未配置快照 → 窗口视为消失")
    }

    // MARK: - 校准与触发

    func test_calibratePoint_invokesOnCalibrate() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)
        var calibrated: TokenUsageProvider?
        scheduler.onCalibrate = { calibrated = $0 }

        scheduler.sync(limits: makeLimits(provider: .claude, resetOffset: 3600))
        scheduling.fire(through: now.addingTimeInterval(3540))

        XCTAssertEqual(calibrated, .claude)
    }

    func test_firePoint_invokesOnFireOnce() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)
        var records: [TokenResetAlarmScheduler.AlarmRecord] = []
        scheduler.onFire = { records.append($0) }

        scheduler.sync(limits: makeLimits(usedPercent: 90, resetOffset: 3600))
        let resetDate = now.addingTimeInterval(3600)
        scheduling.fire(through: resetDate)
        scheduling.fire(through: resetDate)

        XCTAssertEqual(records.count, 1, "单发闹钟不重复触发")
        XCTAssertEqual(records.first?.provider, .codex)
        XCTAssertEqual(records.first?.windowKey, "codex.weekly")
        XCTAssertEqual(records.first?.usedPercent, 90)
    }

    func test_fireBeyondGrace_noCallback() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)
        var callCount = 0
        scheduler.onFire = { _ in callCount += 1 }

        scheduler.sync(limits: makeLimits(resetOffset: 3600))
        // 睡眠/关机超过 5 分钟宽限：只清理不补播。
        now = now.addingTimeInterval(3600 + 400)
        scheduling.fire(through: now)

        XCTAssertEqual(callCount, 0)
    }

    // MARK: - 持久化恢复 / 挂起

    func test_restore_rebuildsAlarmsFromPersistence() {
        let first = FakeOneShotScheduler()
        makeScheduler(scheduling: first).sync(limits: makeLimits(resetOffset: 3600))

        // 新实例（模拟冷启动）：从同一 UserDefaults 恢复布防。
        // 持有引用 — scheduler 释放会随 AnyCancellable 取消布防。
        let second = FakeOneShotScheduler()
        let restored = makeScheduler(scheduling: second)
        restored.restore()
        XCTAssertEqual(
            second.activeDeadlines,
            [now.addingTimeInterval(3540), now.addingTimeInterval(3600)]
        )
    }

    func test_restore_expiredRecord_cleansUpWithoutFiring() {
        let first = FakeOneShotScheduler()
        makeScheduler(scheduling: first).sync(limits: makeLimits(resetOffset: -400))

        let second = FakeOneShotScheduler()
        var callCount = 0
        let restored = makeScheduler(scheduling: second)
        restored.onFire = { _ in callCount += 1 }
        restored.restore()
        // 恢复即到期：宽限外只清理，不误报长关机积压。
        second.fire(through: now)

        XCTAssertEqual(callCount, 0)
    }

    func test_suspend_cancelsAllAlarms() {
        let scheduling = FakeOneShotScheduler()
        let scheduler = makeScheduler(scheduling: scheduling)

        scheduler.sync(limits: makeLimits(resetOffset: 3600))
        scheduler.suspend()

        XCTAssertTrue(scheduling.activeDeadlines.isEmpty)
        scheduling.fire(through: now.addingTimeInterval(4000))
    }
}
