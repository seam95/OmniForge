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

    // MARK: - CPU 高负载（持续时间窗 + 回滞 + 冷却）

    /// 按固定间隔喂高负载采样，模拟真实采样节奏。
    private func feedHighLoad(samples: Int, interval: TimeInterval = 2) {
        for _ in 0..<samples {
            coordinator.handleCPUSample(percent: 85)
            now += interval
        }
    }

    func test_highLoadRequiresSustainedDuration() {
        // 连续覆盖 8s 不足 10s：不触发（首采样不计时，5 个采样覆盖 4×2s）。
        feedHighLoad(samples: 5, interval: 2)
        XCTAssertTrue(spy.events.isEmpty)

        // 再覆盖 2s 满 10s：触发。
        coordinator.handleCPUSample(percent: 85)

        XCTAssertEqual(spy.events, [.loadSurged])
    }

    func test_highLoadWindowDoesNotShrinkWithFasterSampling() {
        // 0.5s 高频采样（面板打开加速刷新）：同样需要累计满 10s，加速不应缩短时间窗。
        feedHighLoad(samples: 20, interval: 0.5)
        XCTAssertTrue(spy.events.isEmpty, "9.5s 高负载不应触发")

        coordinator.handleCPUSample(percent: 85)
        XCTAssertEqual(spy.events, [.loadSurged])
    }

    func test_sampleGapIsCapped() {
        // 采样暂停很久后恢复：间隙不得一次性计入持续窗口。
        coordinator.handleCPUSample(percent: 85)
        now += 3600
        coordinator.handleCPUSample(percent: 85)
        XCTAssertTrue(spy.events.isEmpty, "单帧 + 巨大间隙不应触发")
    }

    func test_singleSpikeDoesNotFire() {
        coordinator.handleCPUSample(percent: 95)
        now += 2
        coordinator.handleCPUSample(percent: 40)

        XCTAssertTrue(spy.events.isEmpty)
    }

    func test_hysteresisBandDoesNotAccumulateOrReset() {
        feedHighLoad(samples: 3, interval: 2)
        // 60-80% 缓冲区：不清零也不累计（但采样时刻照常刷新）。
        now += 2
        coordinator.handleCPUSample(percent: 70)
        now += 2
        coordinator.handleCPUSample(percent: 85)
        XCTAssertTrue(spy.events.isEmpty, "4+4s 超阈覆盖但缓冲区期间语义未清零")

        // 明确回落清零后需重新覆盖满 10s。
        now += 2
        coordinator.handleCPUSample(percent: 40)
        feedHighLoad(samples: 5, interval: 2)
        XCTAssertTrue(spy.events.isEmpty)
        coordinator.handleCPUSample(percent: 85)
        XCTAssertEqual(spy.events, [.loadSurged])
    }

    func test_loadCooldownBlocksUntilRecovery() {
        feedHighLoad(samples: 6, interval: 2)
        XCTAssertEqual(spy.events.count, 1)

        // 冷却期内再次满 10s：不触发。
        now += 100
        feedHighLoad(samples: 6, interval: 2)
        XCTAssertEqual(spy.events.count, 1)

        // 回落到 ≤60% 解除武装后：可再次触发。
        now += 2
        coordinator.handleCPUSample(percent: 50)
        feedHighLoad(samples: 6, interval: 2)
        XCTAssertEqual(spy.events.count, 2)
    }

    // MARK: - 剪贴板（首条目 id 边沿 + 时间戳不回退）

    func test_clipboardFiresOnNewHeadEntryOnly() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        // 建基线：不触发。
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0)
        XCTAssertTrue(spy.events.isEmpty)

        // 新条目入首（新 id + 时间戳更新）：触发。
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(5))
        XCTAssertEqual(spy.events, [.clipboardActivity])

        // 去重置顶：id 复用（ClipboardHistoryManager 去重保持原 id），不触发。
        let head = UUID()
        coordinator.handleClipboardHead(id: head, createdAt: t0.addingTimeInterval(10))
        coordinator.handleClipboardHead(id: head, createdAt: t0.addingTimeInterval(20))
        XCTAssertEqual(spy.events.count, 1, "同 id 置顶（去重）不应触发")
    }

    func test_clipboardCapReplacementStillFires() {
        // 达上限去旧：条目数不变，但首条目是新 id 且时间戳更新 → 应触发（旧计数判据的盲区）。
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0)
        XCTAssertTrue(spy.events.isEmpty)

        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(5))
        XCTAssertEqual(spy.events, [.clipboardActivity])
    }

    func test_clipboardClearingHistoryDoesNotFire() {
        // 清空历史：首条目换成旧条目（id 变了但时间戳回退）→ 不触发。
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0)

        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(-60))
        XCTAssertTrue(spy.events.isEmpty)

        // 清空后的首次新复制（时间戳超过基线）：触发。
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(5))
        XCTAssertEqual(spy.events, [.clipboardActivity])
    }

    func test_clipboardNilHeadDoesNotArmEdge() {
        // 首次为空（历史为空）：建基线不触发；随后新条目触发。
        coordinator.handleClipboardHead(id: nil, createdAt: nil)
        XCTAssertTrue(spy.events.isEmpty)

        coordinator.handleClipboardHead(id: UUID(), createdAt: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(spy.events, [.clipboardActivity])
    }

    func test_clipboardCooldown() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0)
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(5))
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(6))
        XCTAssertEqual(spy.events.count, 1, "60s 冷却内不重复")

        now += 61
        coordinator.handleClipboardHead(id: UUID(), createdAt: t0.addingTimeInterval(7))
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
