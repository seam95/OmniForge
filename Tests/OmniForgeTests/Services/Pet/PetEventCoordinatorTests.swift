import XCTest
@testable import OmniForge

/// 事件协调器测试：五源触发、冷却、下降沿、CPU 持续窗口与回滞、输入法边沿。
@MainActor
final class PetEventCoordinatorTests: XCTestCase {
    /// 记录投递事件的假出口。
    private final class SinkSpy {
        var events: [PetExternalEvent] = []
        /// 可配置的接受结果（默认全接受）。
        var accept: (PetExternalEvent) -> Bool = { _ in true }

        @MainActor
        var handler: (PetExternalEvent) -> Bool { { event in
            let accepted = self.accept(event)
            if accepted { self.events.append(event) }
            return accepted
        } }
    }

    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var spy: SinkSpy!
    private var coordinator: PetEventCoordinator!

    override func setUp() {
        super.setUp()
        spy = SinkSpy()
        coordinator = PetEventCoordinator(now: { [self] in now }, sink: spy.handler)
    }

    override func tearDown() {
        coordinator = nil
        spy = nil
        super.tearDown()
    }

    // MARK: - 限额重置

    func test_limitResetDeliversImmediatelyWithoutCooldown() {
        coordinator.handleLimitReset()
        coordinator.handleLimitReset()

        XCTAssertEqual(spy.events, [.celebrationTriggered, .celebrationTriggered])
    }

    // MARK: - 限额告急（下降沿 + 冷却）

    func test_shortageFiresOnFallingEdgeOnly() {
        // 首次进入告急区（上次无穷大 > 10）触发。
        coordinator.handleLimitsUpdate(shortagePercent: 8)
        XCTAssertEqual(spy.events, [.attentionRequested])

        // 已在告急区继续刷新：不重复。
        coordinator.handleLimitsUpdate(shortagePercent: 5)
        XCTAssertEqual(spy.events.count, 1)

        // 回到安全区再进入：冷却期满后再次触发。
        now += 601
        coordinator.handleLimitsUpdate(shortagePercent: 50)
        coordinator.handleLimitsUpdate(shortagePercent: 9)
        XCTAssertEqual(spy.events.count, 2)
    }

    func test_shortageSafeZoneNeverFires() {
        coordinator.handleLimitsUpdate(shortagePercent: 50)
        coordinator.handleLimitsUpdate(shortagePercent: 11)

        XCTAssertTrue(spy.events.isEmpty)
    }

    func test_shortageNilDataDoesNotArmEdge() {
        // 首次为 nil 不触发；随后 8% 视为下降沿（上次 nil 视为安全）。
        coordinator.handleLimitsUpdate(shortagePercent: nil)
        coordinator.handleLimitsUpdate(shortagePercent: 8)

        XCTAssertEqual(spy.events, [.attentionRequested])
    }

    func test_shortageRespectsCooldown() {
        coordinator.handleLimitsUpdate(shortagePercent: 8)
        // 回安全区再进告急区，但冷却内：不触发。
        coordinator.handleLimitsUpdate(shortagePercent: 50)
        coordinator.handleLimitsUpdate(shortagePercent: 9)
        XCTAssertEqual(spy.events.count, 1)

        // 冷却期满（600s）：触发。
        now += 601
        coordinator.handleLimitsUpdate(shortagePercent: 50)
        coordinator.handleLimitsUpdate(shortagePercent: 9)
        XCTAssertEqual(spy.events.count, 2)
    }

    // MARK: - CPU 高负载（持续窗口 + 回滞 + 冷却）

    func test_highLoadRequiresSustainedStreak() {
        // 4 次不够，第 5 次触发。
        for _ in 0..<4 { coordinator.handleCPUSample(percent: 85) }
        XCTAssertTrue(spy.events.isEmpty)
        coordinator.handleCPUSample(percent: 85)

        XCTAssertEqual(spy.events, [.loadSurged])
    }

    func test_singleSpikeDoesNotFire() {
        coordinator.handleCPUSample(percent: 95)
        coordinator.handleCPUSample(percent: 40)

        XCTAssertTrue(spy.events.isEmpty)
    }

    func test_hysteresisBandDoesNotAccumulateOrReset() {
        for _ in 0..<3 { coordinator.handleCPUSample(percent: 85) }
        // 60-80% 缓冲区：不清零也不累计。
        coordinator.handleCPUSample(percent: 70)
        coordinator.handleCPUSample(percent: 85)
        XCTAssertTrue(spy.events.isEmpty, "3+1+1 次超阈但 streak 中断于缓冲区语义未清零")

        // 明确回落清零后需重新累计满 5 次。
        coordinator.handleCPUSample(percent: 40)
        for _ in 0..<4 { coordinator.handleCPUSample(percent: 85) }
        XCTAssertTrue(spy.events.isEmpty)
        coordinator.handleCPUSample(percent: 85)
        XCTAssertEqual(spy.events, [.loadSurged])
    }

    func test_loadCooldownBlocksUntilRecovery() {
        for _ in 0..<5 { coordinator.handleCPUSample(percent: 85) }
        XCTAssertEqual(spy.events.count, 1)

        // 冷却期内再次满 5 次：不触发。
        now += 100
        for _ in 0..<5 { coordinator.handleCPUSample(percent: 85) }
        XCTAssertEqual(spy.events.count, 1)

        // 回落到 ≤60% 解除武装后：可再次触发。
        coordinator.handleCPUSample(percent: 50)
        for _ in 0..<5 { coordinator.handleCPUSample(percent: 85) }
        XCTAssertEqual(spy.events.count, 2)
    }

    // MARK: - 剪贴板

    func test_clipboardFiresOnCountIncreaseOnly() {
        coordinator.handleClipboardEntries(count: 10)
        XCTAssertTrue(spy.events.isEmpty)

        coordinator.handleClipboardEntries(count: 11)
        XCTAssertEqual(spy.events, [.clipboardActivity])

        // 数量不减（去重置顶不触发）：无事件。
        coordinator.handleClipboardEntries(count: 11)
        XCTAssertEqual(spy.events.count, 1)
    }

    func test_clipboardCooldown() {
        coordinator.handleClipboardEntries(count: 10)
        coordinator.handleClipboardEntries(count: 11)
        coordinator.handleClipboardEntries(count: 12)
        XCTAssertEqual(spy.events.count, 1, "60s 冷却内不重复")

        now += 61
        coordinator.handleClipboardEntries(count: 13)
        XCTAssertEqual(spy.events.count, 2)
    }

    // MARK: - 输入法

    func test_inputLockFiresOnEdgeOnly() {
        coordinator.handleInputLock(locked: true)   // 建基线，不触发
        XCTAssertTrue(spy.events.isEmpty)

        coordinator.handleInputLock(locked: true)   // 同值不触发
        XCTAssertTrue(spy.events.isEmpty)

        coordinator.handleInputLock(locked: false)  // 边沿：解锁
        XCTAssertEqual(spy.events, [.inputLockChanged(locked: false)])

        coordinator.handleInputLock(locked: true)   // 边沿：锁定
        XCTAssertEqual(spy.events.last, .inputLockChanged(locked: true))
    }

    // MARK: - 出口拒绝时不烧冷却

    func test_rejectedEventDoesNotBurnCooldown() {
        // 引擎拒绝（如拖拽中）：不记录冷却时间，下次仍可触发。
        spy.accept = { _ in false }
        coordinator.handleLimitsUpdate(shortagePercent: 8)
        XCTAssertTrue(spy.events.isEmpty)

        spy.accept = { _ in true }
        coordinator.handleLimitsUpdate(shortagePercent: 50)
        coordinator.handleLimitsUpdate(shortagePercent: 9)
        XCTAssertEqual(spy.events, [.attentionRequested])
    }

    // MARK: - 状态重置

    func test_resetStateRestartsFreshBaseline() {
        coordinator.handleLimitsUpdate(shortagePercent: 8)
        XCTAssertEqual(spy.events.count, 1)

        // 重置后基线视为未知（安全区）：冷却与边沿全部清空。
        now += 700
        coordinator.resetState()
        coordinator.handleLimitsUpdate(shortagePercent: 8)
        XCTAssertEqual(spy.events.count, 2, "重置后冷启动发现告急应再次提醒")
    }
}
