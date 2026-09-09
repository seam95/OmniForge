import XCTest
@testable import OmniForge

/// 桌面宠物 Manager 生命周期与偏好测试：
/// 建窗 / 拆窗、尺寸与穿透持久化、位置恢复与夹屏、可插拔停用契约。
@MainActor
final class DesktopPetManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// 本用例创建的 Manager，tearDown 统一 teardown 停表。
    private var managers: [DesktopPetManager] = []

    private let screen = PetScreenGeometry(
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
        identifier: "display-1"
    )

    override func setUp() {
        super.setUp()
        suiteName = "DesktopPetManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        // 先停掉所有行为循环，再释放 defaults，避免残留任务访问已失效对象。
        for manager in managers { manager.teardown() }
        managers.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeManager(
        windowController: PetWindowController? = nil,
        tickInterval: TimeInterval = 3600
    ) -> DesktopPetManager {
        // 字符串源不捕获 self，避免测试结束后残留 tick 任务访问已释放的 defaults。
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: windowController ?? PetWindowController(size: .medium),
            stringsProvider: { Strings.zhHans },
            visibleScreensProvider: { [PetScreenGeometry(
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
                identifier: "display-1"
            )] },
            tickInterval: tickInterval
        )
        managers.append(manager)
        return manager
    }

    // MARK: - 生命周期

    func test_startCreatesPanelAndTeardownClosesIt() {
        let manager = makeManager()

        manager.start()
        XCTAssertNotNil(manager.windowController.panel, "start 后应建立窗口")

        manager.teardown()
        XCTAssertNil(manager.windowController.panel, "teardown 后窗口应消失")
    }

    func test_teardownResetsBehaviorStateAndStopsLoop() {
        let manager = makeManager()
        manager.start()
        manager.pet()

        manager.teardown()

        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_startIsIdempotent() {
        let manager = makeManager()
        manager.start()
        let firstPanel = manager.windowController.panel

        manager.start()

        XCTAssertTrue(manager.windowController.panel === firstPanel, "重复 start 不应重建窗口")
    }

    func test_teardownIsSafeWithoutStart() {
        let manager = makeManager()

        manager.teardown()

        XCTAssertNil(manager.windowController.panel)
    }

    func test_submitExternalEventDoesNotChangeBehavior() {
        let manager = makeManager()
        manager.start()

        manager.submit(.celebrationTriggered)

        // 一期：事件只入队，不影响行为状态。
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    // MARK: - 偏好持久化

    func test_sizeDefaultsToMediumAndPersists() {
        let manager = makeManager()

        XCTAssertEqual(manager.size, .medium)

        manager.setSize(.large)

        XCTAssertEqual(manager.size, .large)
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.petSize), DesktopPetSize.large.rawValue)
    }

    func test_sizeRestoredFromDefaults() {
        defaults.set(DesktopPetSize.small.rawValue, forKey: UserDefaultsKeys.petSize)

        let manager = makeManager()

        XCTAssertEqual(manager.size, .small)
    }

    func test_invalidStoredSizeFallsBackToMedium() {
        defaults.set(999, forKey: UserDefaultsKeys.petSize)

        let manager = makeManager()

        XCTAssertEqual(manager.size, .medium)
    }

    func test_clickThroughPersists() {
        let manager = makeManager()
        manager.start()

        manager.setClickThrough(true)

        XCTAssertTrue(manager.isClickThrough)
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.petClickThrough))
        XCTAssertTrue(manager.windowController.isClickThrough)
    }

    func test_clickThroughRestoredOnInit() {
        defaults.set(true, forKey: UserDefaultsKeys.petClickThrough)

        let manager = makeManager()

        XCTAssertTrue(manager.isClickThrough)
    }

    // MARK: - 位置恢复

    func test_startWithoutStoredPositionLandsOnGround() {
        let manager = makeManager()

        manager.start()

        let origin = manager.windowController.currentOrigin
        XCTAssertEqual(origin?.y, screen.groundY)
    }

    func test_startRestoresStoredPositionClampedToScreen() {
        // 存一个越界位置：应被夹回可见区。
        defaults.set("display-1", forKey: UserDefaultsKeys.petPositionScreen)
        defaults.set(99999.0, forKey: UserDefaultsKeys.petPositionX)
        defaults.set(-99999.0, forKey: UserDefaultsKeys.petPositionY)

        let manager = makeManager()
        manager.start()

        let origin = manager.windowController.currentOrigin
        XCTAssertEqual(origin?.x, screen.visibleFrame.maxX - DesktopPetSize.medium.pointSize)
        XCTAssertEqual(origin?.y, screen.groundY)
    }

    func test_storedPositionOnMissingScreenIsClampedToMainScreen() {
        // SPEC §3：记忆的屏幕已不存在时，位置夹回主屏可见区（而非丢弃坐标）。
        defaults.set("display-removed", forKey: UserDefaultsKeys.petPositionScreen)
        defaults.set(500.0, forKey: UserDefaultsKeys.petPositionX)
        defaults.set(300.0, forKey: UserDefaultsKeys.petPositionY)

        let manager = makeManager()
        manager.start()

        let origin = manager.windowController.currentOrigin
        XCTAssertEqual(origin?.x, 500)
        XCTAssertEqual(origin?.y, 300)
        let center = CGPoint(
            x: (origin?.x ?? 0) + DesktopPetSize.medium.pointSize / 2,
            y: (origin?.y ?? 0) + DesktopPetSize.medium.pointSize / 2
        )
        XCTAssertTrue(screen.visibleFrame.contains(center))
    }

    func test_storedOutOfBoundsPositionIsClampedIntoVisibleFrame() {
        defaults.set("display-1", forKey: UserDefaultsKeys.petPositionScreen)
        defaults.set(99_999.0, forKey: UserDefaultsKeys.petPositionX)
        defaults.set(99_999.0, forKey: UserDefaultsKeys.petPositionY)

        let manager = makeManager()
        manager.start()

        let origin = manager.windowController.currentOrigin
        XCTAssertEqual(origin?.x, screen.visibleFrame.maxX - DesktopPetSize.medium.pointSize)
        XCTAssertEqual(origin?.y, screen.visibleFrame.maxY - DesktopPetSize.medium.pointSize)
    }

    func test_resetPositionMovesPetToGround() {
        let manager = makeManager()
        manager.start()
        manager.windowController.move(to: CGPoint(x: 100, y: 500))

        manager.resetPosition()

        let origin = manager.windowController.currentOrigin
        XCTAssertEqual(origin?.y, screen.groundY)
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    // MARK: - 交互

    func test_petEntersPettedThenReturns() {
        let manager = makeManager()
        manager.start()

        manager.pet()
        XCTAssertEqual(manager.behaviorState, .petted(resumeState: .idle))

        // 单帧推进使抚摸动画播完（测试 tickInterval 很长，一帧即超时）。
        manager.tick()

        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_beginDragThenEndDragOnGroundReturnsToIdle() {
        let manager = makeManager()
        manager.start()

        manager.beginDrag()
        XCTAssertEqual(manager.behaviorState, .drag)

        manager.endDrag()

        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_endDragInAirEntersFall() {
        let manager = makeManager()
        manager.start()
        manager.beginDrag()
        manager.windowController.move(to: CGPoint(x: 200, y: 600))

        manager.endDrag()

        XCTAssertEqual(manager.behaviorState, .fall)
    }

    func test_fallLandsAndReturnsToIdle() {
        let manager = makeManager(tickInterval: 1.0 / 60.0)
        manager.start()
        manager.beginDrag()
        manager.windowController.move(to: CGPoint(x: 200, y: 400))
        manager.endDrag()
        XCTAssertEqual(manager.behaviorState, .fall)

        // 推进足够多帧直到落地。
        for _ in 0..<300 where manager.behaviorState == .fall {
            manager.tick()
        }

        XCTAssertEqual(manager.behaviorState, .idle)
        XCTAssertEqual(manager.windowController.currentOrigin?.y, screen.groundY)
    }

    func test_screenConfigurationChangeClampsAndResetsToIdle() {
        let manager = makeManager()
        manager.start()
        manager.pet()

        manager.handleScreenConfigurationChange()

        XCTAssertEqual(manager.behaviorState, .idle)
        let origin = manager.windowController.currentOrigin
        XCTAssertEqual(origin?.y, screen.groundY)
    }

    func test_requestHideWritesEnabledFalse() {
        defaults.set(true, forKey: UserDefaultsKeys.petEnabled)
        let manager = makeManager()

        manager.requestHide()

        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.petEnabled))
    }
}
