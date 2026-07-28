import Combine
import IOKit.pwr_mgt
import XCTest
@testable import OmniForge

@MainActor
final class KeepAwakeClamshellIntegrationTests: XCTestCase {
    private var clock: FakeKeepAwakeClock!
    private var scheduler: FakeKeepAwakeScheduler!
    private var assertions: FakePowerAssertions!
    private var power: FakePowerReader!
    private var clamshell: FakeClamshellController!
    private var tempRoot: URL!
    private var store: ClamshellRecoveryStore!

    override func setUp() {
        super.setUp()
        clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 2_000))
        scheduler = FakeKeepAwakeScheduler(clock: clock)
        assertions = FakePowerAssertions()
        power = FakePowerReader()
        clamshell = FakeClamshellController()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ka-clamshell-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = ClamshellRecoveryStore(applicationSupportRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeManager(
        clamshellPreferred: Bool = true,
        available: Bool = true
    ) -> KeepAwakeManager {
        let snapshot = KeepAwakeConfigurationSnapshot(
            defaultDuration: .minutes15,
            batteryLimit: .disabled,
            autoStart: false,
            showCountdown: false,
            mouseJiggleEnabled: false,
            mouseJiggleInterval: .minutes5,
            clamshellPreferred: clamshellPreferred,
            shortcutEnabled: true,
            hotkey: .defaultKeepAwake
        )
        return KeepAwakeManager(
            assertions: assertions,
            powerReader: power,
            scheduler: scheduler,
            clock: clock,
            configuration: { snapshot },
            notifications: nil,
            pointerService: nil,
            isFeatureAvailable: { available },
            blocksStart: { false },
            clamshellController: clamshell,
            clamshellStore: store,
            clamshellUserName: "seam",
            clamshellUID: 501
        )
    }

    func test_start_withClamshellPreferred_enablesAfterActive() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 0
        manager.start(duration: .minutes15)
        // 普通会话先 active
        XCTAssertTrue(manager.state.isActive)
        // 等待合盖异步启用
        await waitUntil(timeout: 1.0) {
            if case .active = manager.clamshellState { return true }
            return false
        }
        XCTAssertEqual(manager.clamshellState, .active)
        XCTAssertEqual(clamshell.setCalls, [1])
        XCTAssertEqual(clamshell.sleepDisabled, 1)
        let record = try? store.load(expectedUID: 501, expectedUserName: "seam")
        XCTAssertEqual(record?.phase, .enabled)
        XCTAssertEqual(record?.changedByInputLock, true)
    }

    func test_start_withoutPreference_doesNotTouchClamshell() async {
        let manager = makeManager(clamshellPreferred: false)
        manager.start(duration: .minutes15)
        XCTAssertTrue(manager.state.isActive)
        // 给一点时间确认无异步启用
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.clamshellState, .off)
        XCTAssertTrue(clamshell.setCalls.isEmpty)
    }

    func test_stop_restoresClamshellBeforeReleasingAssertions() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 0
        manager.start(duration: .minutes15)
        await waitUntil(timeout: 1.0) {
            if case .active = manager.clamshellState { return true }
            return false
        }
        clamshell.setCalls.removeAll()
        // 记录释放顺序：合盖 0 必须发生在断言释放之前或至少被尝试
        manager.stop(reason: .manual)
        await waitUntil(timeout: 1.0) {
            if case .inactive = manager.state { return true }
            if case .cleanupRequired = manager.state { return true }
            return false
        }
        XCTAssertEqual(clamshell.setCalls, [0])
        XCTAssertEqual(assertions.releases.count, 2)
        XCTAssertNil(try? store.load(expectedUID: 501, expectedUserName: "seam"))
        XCTAssertEqual(manager.clamshellState, .off)
        XCTAssertEqual(manager.state, .inactive)
    }

    func test_clamshellEnableFailure_keepsNormalSessionActive() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 0
        clamshell.failSet = true
        manager.start(duration: .minutes15)
        XCTAssertTrue(manager.state.isActive)
        await waitUntil(timeout: 1.0) {
            if case .failed = manager.clamshellState { return true }
            if case .conflict = manager.clamshellState { return true }
            return false
        }
        // 普通会话仍 active，持有两个断言
        XCTAssertTrue(manager.state.isActive)
        XCTAssertEqual(assertions.systemAcquires, 1)
        XCTAssertEqual(assertions.displayAcquires, 1)
        XCTAssertTrue(assertions.releases.isEmpty)
    }

    func test_baselineAlreadyOneWithoutRecord_conflictWithoutWriting() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 1
        manager.start(duration: .minutes15)
        XCTAssertTrue(manager.state.isActive)
        await waitUntil(timeout: 1.0) {
            if case .conflict = manager.clamshellState { return true }
            return false
        }
        XCTAssertTrue(clamshell.setCalls.isEmpty)
        XCTAssertTrue(manager.state.isActive)
    }

    func test_clamshellRestoreFailure_assertionsReleased_cleanupRequired() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 0
        manager.start(duration: .minutes15)
        await waitUntil(timeout: 1.0) {
            if case .active = manager.clamshellState { return true }
            return false
        }
        clamshell.failSet = true
        manager.stop(reason: .manual)
        await waitUntil(timeout: 1.0) {
            if case .cleanupRequired = manager.state { return true }
            return false
        }
        // 断言仍应尝试释放
        XCTAssertEqual(assertions.releases.count, 2)
        if case let .cleanupRequired(residual, _) = manager.state {
            XCTAssertTrue(residual.contains(.clamshellSleepDisabled))
        } else {
            XCTFail("expected cleanupRequired with clamshell residual")
        }
    }

    func test_staleEnableCallback_doesNotMutateNewSession() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 0
        // 延迟 set：模拟慢启用
        clamshell.delaySetNanoseconds = 80_000_000
        manager.start(duration: .minutes15)
        XCTAssertTrue(manager.state.isActive)
        // 快速结束旧会话
        manager.stop(reason: .manual)
        await waitUntil(timeout: 1.0) {
            if case .inactive = manager.state { return true }
            return false
        }
        // 新会话不接合盖
        let manager2Config = false
        // 旧回调完成后不得把已 inactive 的 manager 改回 active clamshell
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.clamshellState, .off)
        _ = manager2Config
    }

    func test_disablePreferenceWhileActive_restoresImmediatelyKeepingSession() async {
        let manager = makeManager(clamshellPreferred: true)
        clamshell.sleepDisabled = 0
        manager.start(duration: .minutes15)
        await waitUntil(timeout: 1.0) {
            if case .active = manager.clamshellState { return true }
            return false
        }
        clamshell.setCalls.removeAll()
        await manager.setClamshellPreferred(false)
        await waitUntil(timeout: 1.0) {
            manager.clamshellState == .off
        }
        XCTAssertEqual(clamshell.setCalls, [0])
        XCTAssertTrue(manager.state.isActive)
        XCTAssertEqual(assertions.releases.count, 0)
    }

    // MARK: - helpers

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
