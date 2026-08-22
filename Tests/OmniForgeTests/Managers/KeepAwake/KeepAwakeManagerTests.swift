import Combine
import IOKit.pwr_mgt
import XCTest
@testable import OmniForge

final class FakePowerAssertions: PowerAssertionControlling {
    private(set) var systemAcquires = 0
    private(set) var displayAcquires = 0
    private(set) var releases: [PowerAssertionToken] = []
    var failSystem = false
    var failDisplay = false
    var failReleaseIDs: Set<IOPMAssertionID> = []
    private var nextID: IOPMAssertionID = 1

    func acquireSystemAssertion(reason: String) throws -> PowerAssertionToken {
        systemAcquires += 1
        if failSystem { throw KeepAwakeError.systemAssertionFailed(code: 1) }
        let token = PowerAssertionToken(kind: .system, assertionID: nextID)
        nextID += 1
        return token
    }

    func acquireDisplayAssertion(reason: String) throws -> PowerAssertionToken {
        displayAcquires += 1
        if failDisplay { throw KeepAwakeError.displayAssertionFailed(code: 2) }
        let token = PowerAssertionToken(kind: .display, assertionID: nextID)
        nextID += 1
        return token
    }

    func release(_ token: PowerAssertionToken) throws {
        if failReleaseIDs.contains(token.assertionID) {
            throw KeepAwakeError.assertionReleaseFailed(kind: token.kind.rawValue, code: 3)
        }
        releases.append(token)
    }
}

final class FakePowerReader: KeepAwakePowerSourceReading {
    var snapshot = KeepAwakePowerSnapshot(hasBattery: true, isOnBattery: false, percentage: 80)
    var error: KeepAwakeError?

    func read() throws -> KeepAwakePowerSnapshot {
        if let error { throw error }
        return snapshot
    }
}

@MainActor
final class KeepAwakeManagerTests: XCTestCase {
    private var clock: FakeKeepAwakeClock!
    private var scheduler: FakeKeepAwakeScheduler!
    private var assertions: FakePowerAssertions!
    private var power: FakePowerReader!
    private var notifications: FakeUserNotificationPoster!
    private var manager: KeepAwakeManager!

    override func setUp() {
        super.setUp()
        clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 1_000))
        scheduler = FakeKeepAwakeScheduler(clock: clock)
        assertions = FakePowerAssertions()
        power = FakePowerReader()
        notifications = FakeUserNotificationPoster()
        manager = makeManager()
    }

    private func makeManager(
        config: KeepAwakeConfigurationSnapshot? = nil,
        available: Bool = true,
        blocksStart: Bool = false,
        pointer: PointerActivityService? = nil
    ) -> KeepAwakeManager {
        let snapshot = config ?? KeepAwakeConfigurationSnapshot(
            defaultDuration: .minutes15,
            batteryLimit: .disabled,
            autoStart: false,
            showCountdown: false,
            mouseJiggleEnabled: false,
            mouseJiggleInterval: .minutes5,
            clamshellPreferred: false,
            shortcutEnabled: true,
            hotkey: .defaultKeepAwake
        )
        return KeepAwakeManager(
            assertions: assertions,
            powerReader: power,
            scheduler: scheduler,
            clock: clock,
            configuration: { snapshot },
            notifications: notifications,
            pointerService: pointer,
            isFeatureAvailable: { available },
            blocksStart: { blocksStart }
        )
    }

    func test_start_acquiresBothAssertionsBeforeActive() {
        manager.start(duration: .minutes15)
        XCTAssertEqual(assertions.systemAcquires, 1)
        XCTAssertEqual(assertions.displayAcquires, 1)
        XCTAssertTrue(manager.state.isActive)
        XCTAssertEqual(manager.state.endDate, Date(timeIntervalSince1970: 1_000 + 15 * 60))
    }

    func test_start_systemFailure_noTokensAndInactive() {
        assertions.failSystem = true
        manager.start(duration: .indefinite)
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(manager.lastOperationError, .systemAssertionFailed(code: 1))
        XCTAssertEqual(assertions.displayAcquires, 0)
        XCTAssertTrue(assertions.releases.isEmpty)
    }

    func test_start_displayFailure_rollsBackSystem() {
        assertions.failDisplay = true
        manager.start(duration: .indefinite)
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(manager.lastOperationError, .displayAssertionFailed(code: 2))
        XCTAssertEqual(assertions.releases.count, 1)
        XCTAssertEqual(assertions.releases[0].kind, .system)
    }

    func test_start_displayFailure_systemReleaseFails_entersCleanupRequired() {
        assertions.failDisplay = true
        // 第一枚 token id=1；释放失败
        assertions.failReleaseIDs = [1]
        manager.start(duration: .indefinite)
        guard case let .cleanupRequired(residual, _) = manager.state else {
            return XCTFail("expected cleanupRequired, got \(manager.state)")
        }
        XCTAssertTrue(residual.contains(.systemAssertion))
        XCTAssertFalse(residual.contains(.displayAssertion))
    }

    func test_stop_manual_releasesBothAndInactive() async {
        manager.start(duration: .indefinite)
        manager.stop(reason: .manual)
        // stop 异步 cleanup
        await waitForInactiveOrCleanup()
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(assertions.releases.count, 2)
        XCTAssertTrue(notifications.requests.isEmpty, "manual stop should not notify")
    }

    func test_deadline_endsWithDurationElapsedAndNotifies() async {
        manager.start(duration: .minutes15)
        let end = Date(timeIntervalSince1970: 1_000 + 15 * 60)
        scheduler.advance(to: end)
        await waitForInactiveOrCleanup()
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(notifications.requests.count, 1)
    }

    /// 模拟睡眠：墙钟越过 endDate，但不触发 once deadline（DispatchTime 被冻住）。
    func test_reconcile_endsExpiredSessionWhenDeadlineTimerMissed() async {
        manager.start(duration: .minutes15)
        XCTAssertTrue(manager.state.isActive)
        // 只推进墙钟，不 fire once 任务
        clock.now = Date(timeIntervalSince1970: 1_000 + 15 * 60 + 30)
        manager.reconcileExpiredDeadlineIfNeeded(trigger: "NSWorkspaceDidWakeNotification")
        await waitForInactiveOrCleanup()
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(assertions.releases.count, 2)
        XCTAssertEqual(notifications.requests.count, 1, "durationElapsed 应发通知")
    }

    func test_reconcile_noopWhenNotExpired() {
        manager.start(duration: .minutes15)
        clock.now = Date(timeIntervalSince1970: 1_000 + 60)
        manager.reconcileExpiredDeadlineIfNeeded(trigger: "heartbeat")
        XCTAssertTrue(manager.state.isActive)
        XCTAssertEqual(assertions.releases.count, 0)
    }

    func test_heartbeat_reconcilesExpiredSession() async {
        manager.start(duration: .minutes15)
        clock.now = Date(timeIntervalSince1970: 1_000 + 15 * 60 + 5)
        // 不 fire once；只 fire repeating（含 heartbeat）
        scheduler.fireRepeating()
        await waitForInactiveOrCleanup()
        XCTAssertEqual(manager.state, .inactive)
    }

    func test_extend_updatesDeadline() {
        manager.start(duration: .minutes15)
        manager.extend(byMinutes: 30)
        XCTAssertEqual(
            manager.state.endDate,
            Date(timeIntervalSince1970: 1_000 + 15 * 60 + 30 * 60)
        )
    }

    func test_indefinite_cannotExtend() {
        manager.start(duration: .indefinite)
        manager.extend(byMinutes: 15)
        XCTAssertNil(manager.state.endDate)
        XCTAssertEqual(manager.lastOperationError, .operationInProgress)
    }

    func test_staleDeadline_doesNotEndNewSession() async {
        manager.start(duration: .minutes15)
        let oldEnd = manager.state.endDate!
        manager.stop(reason: .manual)
        await waitForInactiveOrCleanup()
        manager.start(duration: .indefinite)
        XCTAssertTrue(manager.state.isActive)
        // 旧 deadline 触发
        scheduler.advance(to: oldEnd)
        // 仍应保持新会话
        XCTAssertTrue(manager.state.isActive)
        XCTAssertNil(manager.state.endDate)
    }

    func test_releaseOneFails_stillAttemptsOther_andCleanupRequired() async {
        manager.start(duration: .indefinite)
        // display token id=2 失败
        assertions.failReleaseIDs = [2]
        manager.stop(reason: .manual)
        await waitForInactiveOrCleanup()
        guard case let .cleanupRequired(residual, _) = manager.state else {
            return XCTFail("expected cleanupRequired, got \(manager.state)")
        }
        XCTAssertTrue(residual.contains(.displayAssertion))
        // system 应已尝试释放
        XCTAssertTrue(assertions.releases.contains { $0.kind == .system })
    }

    func test_lowBattery_endsSession() async {
        let config = KeepAwakeConfigurationSnapshot(
            defaultDuration: .indefinite,
            batteryLimit: .percent10,
            autoStart: false,
            showCountdown: false,
            mouseJiggleEnabled: false,
            mouseJiggleInterval: .minutes5,
            clamshellPreferred: false,
            shortcutEnabled: true,
            hotkey: .defaultKeepAwake
        )
        manager = makeManager(config: config)
        power.snapshot = KeepAwakePowerSnapshot(hasBattery: true, isOnBattery: true, percentage: 50)
        manager.start()
        XCTAssertTrue(manager.state.isActive)

        power.snapshot = KeepAwakePowerSnapshot(hasBattery: true, isOnBattery: true, percentage: 10)
        scheduler.fireRepeating()
        await waitForInactiveOrCleanup()
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(notifications.requests.count, 1)
    }

    func test_startBlockedWhenFeatureUnavailable() {
        manager = makeManager(available: false)
        manager.start()
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(manager.lastOperationError, .featureUnavailable)
        XCTAssertEqual(assertions.systemAcquires, 0)
    }

    func test_preStartBatteryReadFailure_createsNoAssertions() {
        let config = KeepAwakeConfigurationSnapshot(
            defaultDuration: .indefinite,
            batteryLimit: .percent10,
            autoStart: false,
            showCountdown: false,
            mouseJiggleEnabled: false,
            mouseJiggleInterval: .minutes5,
            clamshellPreferred: false,
            shortcutEnabled: true,
            hotkey: .defaultKeepAwake
        )
        manager = makeManager(config: config)
        power.error = .batteryReadFailed("boom")
        manager.start()
        XCTAssertEqual(manager.state, .inactive)
        XCTAssertEqual(assertions.systemAcquires, 0)
    }

    func test_setDuration_updatesActiveSessionEndDate() {
        manager.start(duration: .minutes15)
        guard case let .active(end1?) = manager.state else {
            XCTFail("Expected timed active state")
            return
        }
        XCTAssertEqual(end1, Date(timeIntervalSince1970: 1_000 + 15 * 60))

        // 切换到 1 小时
        manager.setDuration(.minutes60)
        guard case let .active(end2?) = manager.state else {
            XCTFail("Expected timed active state after switching duration")
            return
        }
        XCTAssertEqual(end2, Date(timeIntervalSince1970: 1_000 + 60 * 60))

        // 切换到无限期
        manager.setDuration(.indefinite)
        guard case let .active(end3) = manager.state else {
            XCTFail("Expected active state")
            return
        }
        XCTAssertNil(end3)
    }

    private func waitForInactiveOrCleanup(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch manager.state {
            case .inactive, .cleanupRequired:
                return
            default:
                await Task.yield()
            }
        }
    }
}
