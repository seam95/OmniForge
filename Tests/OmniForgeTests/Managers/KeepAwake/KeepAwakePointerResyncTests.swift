import Combine
import CoreGraphics
import XCTest
@testable import OmniForge

/// Manager 活动中微动配置即时同步（SPEC §5.8）。
@MainActor
final class KeepAwakePointerResyncTests: XCTestCase {
    private var clock: FakeKeepAwakeClock!
    private var scheduler: FakeKeepAwakeScheduler!
    private var assertions: FakePowerAssertions!
    private var power: FakePowerReader!
    private var poster: FakePointerPoster!
    private var pointerService: PointerActivityService!
    private var configBox: ConfigBox!

    override func setUp() {
        super.setUp()
        clock = FakeKeepAwakeClock(now: Date(timeIntervalSince1970: 1_000))
        scheduler = FakeKeepAwakeScheduler(clock: clock)
        assertions = FakePowerAssertions()
        power = FakePowerReader()
        poster = FakePointerPoster()
        pointerService = PointerActivityService(
            poster: poster,
            scheduler: scheduler,
            clock: clock,
            isAccessibilityTrusted: { true }
        )
        configBox = ConfigBox(snapshot: Self.baseSnapshot(jiggleEnabled: false, interval: .minutes5))
    }

    func test_resync_whenInactive_doesNotTouchPointer() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .inactive)

        manager.resyncPointerActivityFromConfiguration()

        XCTAssertTrue(poster.posts.isEmpty)
        XCTAssertTrue(pointerRepeatingTasks.isEmpty)
        XCTAssertNil(manager.pointerActivityError)
        XCTAssertNil(manager.lastOperationError)
    }

    func test_resync_whenActive_startsPointerWithNewInterval() {
        // 先以微动关闭启动 active 会话
        let manager = makeManager()
        manager.start(duration: .indefinite)
        XCTAssertTrue(manager.state.isActive)
        XCTAssertTrue(poster.posts.isEmpty)

        // 活动中改配置：开启微动、间隔 1 分钟
        configBox.snapshot = Self.baseSnapshot(jiggleEnabled: true, interval: .minutes1)
        manager.resyncPointerActivityFromConfiguration()

        XCTAssertFalse(poster.posts.isEmpty, "resync 应立即触发一次微动")
        let activeRepeating = pointerRepeatingTasks
        XCTAssertEqual(activeRepeating.count, 1)
        XCTAssertEqual(activeRepeating[0].interval, TimeInterval(1 * 60))
        XCTAssertNil(manager.lastOperationError)
    }

    func test_resync_whenActive_andConfigInvalid_stopsPointerAndSurfacesError() {
        configBox.snapshot = Self.baseSnapshot(jiggleEnabled: true, interval: .minutes5)
        let manager = makeManager()
        manager.start(duration: .indefinite)
        XCTAssertTrue(manager.state.isActive)
        XCTAssertFalse(poster.posts.isEmpty)

        // 配置非法：应停止微动并写入错误，不静默吞掉
        configBox.error = KeepAwakeError.invalidPointerInterval(3)
        manager.resyncPointerActivityFromConfiguration()

        XCTAssertTrue(pointerRepeatingTasks.isEmpty, "非法配置后应停止微动")
        XCTAssertEqual(manager.pointerActivityError, .invalidPointerInterval(3))
        XCTAssertEqual(manager.lastOperationError, .invalidPointerInterval(3))
    }

    func test_resync_success_clearsPointerRelatedLastOperationError() {
        configBox.snapshot = Self.baseSnapshot(jiggleEnabled: true, interval: .minutes5)
        let manager = makeManager()
        manager.start(duration: .indefinite)
        XCTAssertTrue(manager.state.isActive)

        // 先制造非法配置错误
        configBox.error = KeepAwakeError.invalidPointerInterval(3)
        manager.resyncPointerActivityFromConfiguration()
        XCTAssertEqual(manager.lastOperationError, .invalidPointerInterval(3))
        XCTAssertEqual(manager.pointerActivityError, .invalidPointerInterval(3))

        // 配置恢复合法后成功 resync 应清除相关 lastOperationError
        configBox.error = nil
        configBox.snapshot = Self.baseSnapshot(jiggleEnabled: true, interval: .minutes1)
        manager.resyncPointerActivityFromConfiguration()

        XCTAssertNil(manager.lastOperationError)
        XCTAssertNil(manager.pointerActivityError)
        let activeRepeating = pointerRepeatingTasks
        XCTAssertEqual(activeRepeating.count, 1)
        XCTAssertEqual(activeRepeating[0].interval, TimeInterval(1 * 60))
    }

    /// Manager 诊断心跳(15s)/低电量(30s) 与指针微动共用 Fake 调度器；测试只断言微动任务。
    private var pointerRepeatingTasks: [FakeKeepAwakeScheduler.RepeatingTask] {
        scheduler.repeatingTasks.filter { task in
            !task.cancelled && task.interval != 15 && task.interval != 30
        }
    }

    // MARK: - Helpers

    private func makeManager() -> KeepAwakeManager {
        KeepAwakeManager(
            assertions: assertions,
            powerReader: power,
            scheduler: scheduler,
            clock: clock,
            configuration: { [configBox] in try configBox!.load() },
            pointerService: pointerService,
            isFeatureAvailable: { true },
            blocksStart: { false }
        )
    }

    private static func baseSnapshot(
        jiggleEnabled: Bool,
        interval: KeepAwakePointerInterval
    ) -> KeepAwakeConfigurationSnapshot {
        KeepAwakeConfigurationSnapshot(
            defaultDuration: .indefinite,
            batteryLimit: .disabled,
            autoStart: false,
            showCountdown: false,
            mouseJiggleEnabled: jiggleEnabled,
            mouseJiggleInterval: interval,
            clamshellPreferred: false,
            shortcutEnabled: true,
            hotkey: .defaultKeepAwake
        )
    }
}

/// 可变配置盒：支持活动中改写快照或注入错误。
private final class ConfigBox {
    var snapshot: KeepAwakeConfigurationSnapshot
    var error: Error?

    init(snapshot: KeepAwakeConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> KeepAwakeConfigurationSnapshot {
        if let error { throw error }
        return snapshot
    }
}
