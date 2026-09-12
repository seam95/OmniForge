import XCTest
@testable import OmniForge

/// 桌面宠物 Manager 生命周期与偏好测试：
/// 建窗 / 拆窗、尺寸持久化、帧时钟启停、位置恢复与夹屏、可插拔停用契约。
@MainActor
final class DesktopPetManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// 测试用宠物资产库根目录（隔离临时目录，避免写入真实库）。
    private var assetRoot: URL!
    /// 本用例创建的 Manager，tearDown 统一 teardown 停表。
    private var managers: [DesktopPetManager] = []
    /// 本用例注入的假帧时钟，按创建顺序与 managers 对应。
    private var frameClocks: [ManualFrameClock] = []

    private let screen = PetScreenGeometry(
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
        identifier: "display-1"
    )

    override func setUp() {
        super.setUp()
        suiteName = "DesktopPetManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-assets-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // 先停掉所有行为循环，再释放 defaults，避免残留任务访问已失效对象。
        for manager in managers { manager.teardown() }
        managers.removeAll()
        frameClocks.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: assetRoot)
        assetRoot = nil
        PetAssetLocator.additionalSearchRoots = []
        super.tearDown()
    }

    private func makeManager(
        windowController: PetWindowController? = nil,
        engine: PetBehaviorEngine? = nil,
        tickInterval: TimeInterval = 3600,
        bubbleVariantRoll: Double = 0.1
    ) -> DesktopPetManager {
        // 注入假帧时钟：隔离真实 CADisplayLink 对屏幕 / runloop 的依赖，保证时序确定。
        let clock = ManualFrameClock()
        frameClocks.append(clock)
        // 字符串源不捕获 self，避免测试结束后残留帧回调访问已释放的 defaults。
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: windowController
                ?? PetWindowController(petSize: CGSize(width: 96, height: 96)),
            engine: engine,
            assetStore: PetAssetStore(rootDirectory: assetRoot),
            stringsProvider: { Strings.zhHans },
            visibleScreensProvider: { [PetScreenGeometry(
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
                identifier: "display-1"
            )] },
            tickInterval: tickInterval,
            frameClock: clock,
            bubbleVariantRoll: { bubbleVariantRoll }
        )
        managers.append(manager)
        return manager
    }

    /// 当前用例最后一次创建的假帧时钟。
    private var lastClock: ManualFrameClock? { frameClocks.last }

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

    func test_submitMappedEventEntersReaction() {
        let manager = makeManager()
        manager.start()

        let accepted = manager.submit(.celebrationTriggered(quotaLabel: "Claude 7d"))

        // 二期：已映射事件即时分发为反应态。
        XCTAssertTrue(accepted)
        XCTAssertEqual(manager.behaviorState, .reaction(kind: .celebrate, resumeState: .idle))
    }

    func test_submitUnmappedEventLeavesBehaviorUnchanged() {
        let manager = makeManager()
        manager.start()

        let accepted = manager.submit(.activityStarted(kind: .thinking))

        // 未映射事件（三期 Agent 预留）仍只入队。
        XCTAssertFalse(accepted)
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    // MARK: - 对话气泡

    func test_submitMappedEventPresentsBubbleWithQuotaCopy() {
        let manager = makeManager(bubbleVariantRoll: 0.1)
        manager.start()

        XCTAssertTrue(manager.submit(.celebrationTriggered(quotaLabel: "Claude 7d")))

        XCTAssertEqual(manager.currentBubble?.kind, .celebrate)
        XCTAssertEqual(manager.currentBubble?.text, "Claude 7d 额度重置啦！", "额度文案须含平台与窗口标签")
        XCTAssertNotNil(manager.bubbleController.panel, "反应被接受应展示气泡子窗")
    }

    func test_submitUnmappedEventDoesNotPresentBubble() {
        let manager = makeManager()
        manager.start()

        _ = manager.submit(.activityStarted(kind: .thinking))

        XCTAssertNil(manager.currentBubble)
    }

    func test_bubbleVariantRollPicksSecondCopy() {
        let manager = makeManager(bubbleVariantRoll: 0.9)
        manager.start()

        _ = manager.submit(.loadSurged)

        XCTAssertEqual(manager.currentBubble?.text, "热得受不了啦")
    }

    func test_reactionExpiryClearsBubble() {
        let manager = makeManager()
        manager.start()
        _ = manager.submit(.attentionRequested(quotaLabel: "Claude 7d"))
        XCTAssertNotNil(manager.currentBubble)

        // 反应 3s 到期自然结束：状态回 idle，气泡随之清空。
        manager.tick(delta: 3.1)

        XCTAssertEqual(manager.behaviorState, .idle)
        XCTAssertNil(manager.currentBubble)
    }

    func test_petDuringReactionClearsBubble() {
        let manager = makeManager()
        manager.start()
        _ = manager.submit(.attentionRequested(quotaLabel: "Claude 7d"))

        manager.pet()

        XCTAssertEqual(manager.behaviorState, .petted(resumeState: .idle))
        XCTAssertNil(manager.currentBubble, "抚摸打断反应时气泡立即消失")
    }

    func test_beginDragDuringReactionClearsBubble() {
        let manager = makeManager()
        manager.start()
        _ = manager.submit(.attentionRequested(quotaLabel: "Claude 7d"))

        manager.beginDrag()

        XCTAssertEqual(manager.behaviorState, .drag)
        XCTAssertNil(manager.currentBubble, "拖拽打断反应时气泡立即消失")
    }

    func test_sameLevelReplacementUpdatesBubbleText() {
        let manager = makeManager(bubbleVariantRoll: 0.1)
        manager.start()
        _ = manager.submit(.celebrationTriggered(quotaLabel: "Claude 7d"))
        XCTAssertEqual(manager.currentBubble?.text, "Claude 7d 额度重置啦！")

        // 同级替换（另一平台重置）：换文案、状态仍为 reaction。
        XCTAssertTrue(manager.submit(.celebrationTriggered(quotaLabel: "DeepSeek 5h")))
        XCTAssertEqual(manager.currentBubble?.text, "DeepSeek 5h 额度重置啦！")
        guard case .reaction(let kind, _) = manager.behaviorState else {
            return XCTFail("同级替换后应仍在反应态")
        }
        XCTAssertEqual(kind, .celebrate)
    }

    func test_dismissBubbleClearsContentButKeepsReaction() {
        let manager = makeManager()
        manager.start()
        _ = manager.submit(.attentionRequested(quotaLabel: "Claude 7d"))

        manager.dismissBubble()

        XCTAssertNil(manager.currentBubble, "点击气泡只关气泡")
        XCTAssertEqual(manager.behaviorState, .reaction(kind: .attention, resumeState: .idle), "反应动画继续走完")
    }

    func test_teardownClosesBubblePanel() {
        let manager = makeManager()
        manager.start()
        _ = manager.submit(.attentionRequested(quotaLabel: "Claude 7d"))
        XCTAssertNotNil(manager.bubbleController.panel)

        manager.teardown()

        XCTAssertNil(manager.bubbleController.panel, "teardown 应销毁气泡子窗")
        XCTAssertNil(manager.currentBubble)
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

    // MARK: - 帧时钟

    func test_startStartsFrameClockAndTeardownStopsIt() {
        let manager = makeManager()
        let clock = lastClock

        manager.start()

        XCTAssertEqual(clock?.startCount, 1, "start 应启动帧时钟")
        XCTAssertEqual(clock?.isRunning, true)

        manager.teardown()

        XCTAssertEqual(clock?.stopCount, 1, "teardown 应停止帧时钟")
        XCTAssertEqual(clock?.isRunning, false)
    }

    func test_repeatedStartDoesNotRestartFrameClock() {
        let manager = makeManager()

        manager.start()
        manager.start()

        XCTAssertEqual(lastClock?.startCount, 1, "重复 start 不应重复启动时钟")
    }

    func test_frameClockAdvancesBehaviorWithFrameDelta() {
        let manager = makeManager()
        manager.start()
        manager.pet()
        XCTAssertEqual(manager.behaviorState, .petted(resumeState: .idle))

        // 单帧真实 delta 超过抚摸动画时长 → 回到 idle。
        lastClock?.emit(delta: 5.0)

        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_tickUsesExplicitDeltaOverDefaultInterval() {
        let manager = makeManager(tickInterval: 3600)
        manager.start()
        manager.pet()

        // 显式小 delta 不足以播完抚摸动画。
        manager.tick(delta: 0.001)
        XCTAssertEqual(manager.behaviorState, .petted(resumeState: .idle))

        // 显式大 delta 立即播完。
        manager.tick(delta: 3600)
        XCTAssertEqual(manager.behaviorState, .idle)
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

    // MARK: - 好动程度

    func test_activityPresetDefaultsToBalanced() {
        let manager = makeManager()

        XCTAssertEqual(manager.activityPreset, .balanced)
    }

    func test_activityPresetPersistsAndAppliesToEngine() {
        let manager = makeManager()

        manager.setActivityPreset(.quiet)

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.petActivityLevel), "quiet")
        XCTAssertEqual(manager.activityPreset, .quiet)
    }

    func test_invalidStoredActivityPresetFallsBackToBalanced() {
        defaults.set("bogus", forKey: UserDefaultsKeys.petActivityLevel)

        let manager = makeManager()

        XCTAssertEqual(manager.activityPreset, .balanced)
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

    func test_beginDragThenEndDragReturnsToIdle() {
        let manager = makeManager()
        manager.start()

        manager.beginDrag()
        XCTAssertEqual(manager.behaviorState, .drag)

        manager.endDrag()

        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_endDragInAirHoversAtDropPoint() {
        // 拖到空中松手：宠物悬停原处，不下落。
        let manager = makeManager()
        manager.start()
        manager.beginDrag()
        manager.windowController.move(to: CGPoint(x: 200, y: 600))

        manager.endDrag()

        XCTAssertEqual(manager.behaviorState, .idle)
        XCTAssertEqual(manager.windowController.currentOrigin?.y, 600)
    }

    func test_walkStaysWithinRadiusOfDropPoint() {
        // 松手处成为活动锚点：长时间行走也不越出锚点 ± 半径。
        let manager = makeManager(tickInterval: 1.0 / 30.0)
        manager.start()
        manager.beginDrag()
        manager.windowController.move(to: CGPoint(x: 700, y: 400))
        manager.endDrag()

        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        for _ in 0..<3000 {
            manager.tick()
            if let x = manager.windowController.currentOrigin?.x {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }

        // 活动半径 120，允许 1pt 浮点误差。
        XCTAssertGreaterThanOrEqual(minX, 700 - 120 - 1)
        XCTAssertLessThanOrEqual(maxX, 700 + 120 + 1)
    }

    func test_walkKeepsHoverHeightWhenNotOnGround() {
        // 悬停在半空时行走只改 x，高度不变。
        let manager = makeManager(tickInterval: 1.0 / 30.0)
        manager.start()
        manager.beginDrag()
        manager.windowController.move(to: CGPoint(x: 600, y: 350))
        manager.endDrag()

        for _ in 0..<600 { manager.tick() }

        XCTAssertEqual(manager.windowController.currentOrigin?.y, 350)
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

    // MARK: - 反应总开关运行期切换

    func test_reactionsToggleTakesEffectWhileRunning() {
        // 开关关闭时启动：协调器不建。
        defaults.set(false, forKey: UserDefaultsKeys.petReactionsEnabled)
        let manager = makeManager()
        manager.start()
        XCTAssertNil(manager.reactionCoordinator, "开关关闭时不应建立协调器")

        // 运行中开开关（模拟设置页 Toggle 写键后 sync → start 重入）：即时补订阅。
        defaults.set(true, forKey: UserDefaultsKeys.petReactionsEnabled)
        manager.start()
        XCTAssertNotNil(manager.reactionCoordinator, "运行中开开关应即时建立协调器")

        // 运行中关开关：即时撤订阅。
        defaults.set(false, forKey: UserDefaultsKeys.petReactionsEnabled)
        manager.start()
        XCTAssertNil(manager.reactionCoordinator, "运行中关开关应即时撤掉协调器")
    }

    func test_reactionsDisabledAtStartHasNoCoordinator() {
        defaults.set(false, forKey: UserDefaultsKeys.petReactionsEnabled)
        let manager = makeManager()
        manager.start()

        XCTAssertNil(manager.reactionCoordinator)
    }

    // MARK: - 一次性状态打断保留剩余行走时长

    func test_reactionInterruptingWalkRestoresRemainingDuration() {
        // 种子随机：0.0 → start 的 idle 停留采样（下限 2s）；0.7 → 决策选中 walkLeft；
        // 0.0 → 行走时长下限 1s。
        let engine = PetBehaviorEngine(randomSource: SeededPetRandomSource(values: [0.0, 0.7, 0.0]))
        let manager = makeManager(engine: engine, tickInterval: 1.0 / 30.0)
        manager.start()

        // 推进满 idle 停留时长后触发矩阵决策，进入行走。
        manager.tick(delta: 2.1)
        XCTAssertEqual(manager.behaviorState, .walk(direction: .left))

        // 走 0.5s 后被反应打断：剩 0.5s。
        manager.tick(delta: 0.5)
        XCTAssertTrue(manager.submit(.celebrationTriggered(quotaLabel: "Claude 7d")))
        XCTAssertEqual(
            manager.behaviorState,
            .reaction(kind: .celebrate, resumeState: .walk(direction: .left))
        )

        // 反应 3s 播完：恢复行走且剩余时长还在（再走 0.1s 不应结束）。
        manager.tick(delta: 5.0)
        XCTAssertEqual(manager.behaviorState, .walk(direction: .left))
        manager.tick(delta: 0.1)
        XCTAssertEqual(manager.behaviorState, .walk(direction: .left), "剩余行走时长被打断吞掉")

        // 剩余 0.4s 走完转 idle（小步推进，避免单帧大位移撞活动边界触发转身分支）。
        manager.tick(delta: 0.5)
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_petInterruptingWalkRestoresRemainingDuration() {
        // 种子随机：0.0 → start 的 idle 停留采样；0.7 → walkLeft；0.0 → 时长下限 1s。
        let engine = PetBehaviorEngine(randomSource: SeededPetRandomSource(values: [0.0, 0.7, 0.0]))
        let manager = makeManager(engine: engine, tickInterval: 1.0 / 30.0)
        manager.start()

        manager.tick(delta: 2.1)
        manager.tick(delta: 0.5)
        manager.pet()
        XCTAssertEqual(manager.behaviorState, .petted(resumeState: .walk(direction: .left)))

        // 抚摸播完（无资产兜底 0.6s）：恢复行走且剩余 ~0.5s 仍在。
        manager.tick(delta: 1.0)
        XCTAssertEqual(manager.behaviorState, .walk(direction: .left))
        manager.tick(delta: 0.1)
        XCTAssertEqual(manager.behaviorState, .walk(direction: .left))
        manager.tick(delta: 0.5)
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    // MARK: - 屏幕变更

    func test_screenConfigurationChangeRefreshesWalkAnchor() {
        var screens = [screen]
        let clock = ManualFrameClock()
        frameClocks.append(clock)
        // 种子随机 [0.7, 1.0]：从 idle / walk 行都会持续选 walkLeft（时长 2.5s），长走必到左边界。
        let engine = PetBehaviorEngine(randomSource: SeededPetRandomSource(values: [0.7, 1.0]))
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: PetWindowController(petSize: CGSize(width: 96, height: 96)),
            engine: engine,
            assetStore: PetAssetStore(rootDirectory: assetRoot),
            stringsProvider: { Strings.zhHans },
            visibleScreensProvider: { screens },
            tickInterval: 1.0 / 30.0,
            frameClock: clock
        )
        managers.append(manager)
        manager.start()

        // 宽屏上锚定 1200。
        manager.beginDrag()
        manager.windowController.move(to: CGPoint(x: 1200, y: 400))
        manager.endDrag()

        // 换窄屏（可见区 0…500）：夹回到 ~404，活动锚点应随之更新。
        screens = [PetScreenGeometry(
            visibleFrame: CGRect(x: 0, y: 25, width: 500, height: 800),
            identifier: "display-1"
        )]
        manager.handleScreenConfigurationChange()
        let clampedX = manager.windowController.currentOrigin?.x ?? 0

        // 40s 持续行走：新锚点下最左只能到 clampedX - 120；旧锚点（1200）会使范围退化到全屏 0…404。
        var minX = CGFloat.greatestFiniteMagnitude
        for _ in 0..<400 {
            manager.tick(delta: 0.1)
            if let x = manager.windowController.currentOrigin?.x {
                minX = min(minX, x)
            }
        }
        XCTAssertGreaterThan(minX, clampedX - 120 - 1, "屏幕变更后行走锚点未更新，范围退化为全屏")
    }

    // MARK: - 位置持久化

    func test_teardownPersistsCurrentPosition() {
        let manager = makeManager()
        manager.start()
        manager.windowController.move(to: CGPoint(x: 300, y: 400))

        manager.teardown()

        XCTAssertEqual(defaults.double(forKey: UserDefaultsKeys.petPositionX), 300)
        XCTAssertEqual(defaults.double(forKey: UserDefaultsKeys.petPositionY), 400)
    }

    // MARK: - 内置宠物切换与 slug 迁移（三期：cat → doraemon）

    /// 构造一个库内可加载的自定义宠物目录（自有格式，2×1 网格最小资产）。
    private func installCustomPet(slug: String) throws {
        let directory = assetRoot.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"""
        {
          "id": "\#(slug)",
          "name": "\#(slug)",
          "displayName": "\#(slug)",
          "atlas": "atlas.png",
          "grid": { "columns": 2, "rows": 1, "cellSize": [16, 16] },
          "animations": [{ "id": "idle", "frames": "0-1", "fps": 4, "loop": true }]
        }
        """#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
        // 图集本体不参与 slug 可加载判定（pet.json + 完整解码即算，解码在无图集时
        // 仍成功——图集按需懒加载），pet.json 即可让 customAssetIsLoadable 命中。
    }

    func test_freshDefaultsSelectDoraemon() {
        // 真实 defaults 注册下的首开：未存储 slug 时选择内置 doraemon 并落盘。
        let manager = makeManager()

        XCTAssertEqual(manager.selectedPetSlug, PetAssetLocator.builtInPetID)
        XCTAssertEqual(manager.isCustomPet, false)
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.petSelectedSlug),
            PetAssetLocator.builtInPetID,
            "首开应把内置 slug 落盘"
        )
    }

    func test_legacyCatMigratesToDoraemonWhenNoCustomCat() throws {
        defaults.set(PetAssetLocator.retiredBuiltInPetID, forKey: UserDefaultsKeys.petSelectedSlug)

        let manager = makeManager()

        XCTAssertEqual(
            manager.selectedPetSlug, PetAssetLocator.builtInPetID,
            "旧 cat 且库内无同名自定义资产 → 迁移为 doraemon"
        )
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.petSelectedSlug),
            PetAssetLocator.builtInPetID,
            "迁移结果须落盘（重启后不反复迁移）"
        )
    }

    func test_validCustomCatIsPreserved() throws {
        try installCustomPet(slug: PetAssetLocator.retiredBuiltInPetID)
        defaults.set(PetAssetLocator.retiredBuiltInPetID, forKey: UserDefaultsKeys.petSelectedSlug)

        let manager = makeManager()

        XCTAssertEqual(
            manager.selectedPetSlug, PetAssetLocator.retiredBuiltInPetID,
            "用户自装的 cat 是有效自定义资产，不误迁"
        )
        XCTAssertEqual(manager.isCustomPet, true)
    }

    func test_missingSlugFallsBackToBuiltInAndPersists() {
        defaults.set("ghost-pet", forKey: UserDefaultsKeys.petSelectedSlug)

        let manager = makeManager()

        XCTAssertEqual(manager.selectedPetSlug, PetAssetLocator.builtInPetID)
        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.petSelectedSlug),
            PetAssetLocator.builtInPetID,
            "失效选择回退时同步保存（画面与选中态一致）"
        )
    }

    func test_selectedSlugSurvivesReinit() throws {
        try installCustomPet(slug: "my-pet")
        defaults.set("my-pet", forKey: UserDefaultsKeys.petSelectedSlug)

        let first = makeManager()
        XCTAssertEqual(first.selectedPetSlug, "my-pet")

        // 再次初始化：仍选 my-pet（有效自定义选择稳定保持）。
        managers.append(first)
        let second = makeManager()
        XCTAssertEqual(second.selectedPetSlug, "my-pet")
    }

    // MARK: - 指针采样、看向与悬停（三期覆盖）

    /// 可变指针源盒子：闭包捕获引用，测试期间可直接移动指针。
    private final class PointerBox {
        var location: CGPoint = .zero
    }

    /// 构造带资产与可变指针源的 Manager（覆盖采样测试用）。
    private func makeOverlayManager(
        asset: PetSpriteAsset?,
        pointer: PointerBox = PointerBox()
    ) -> (manager: DesktopPetManager, pointer: PointerBox) {
        let clock = ManualFrameClock()
        frameClocks.append(clock)
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: PetWindowController(petSize: CGSize(width: 96, height: 96)),
            assetStore: PetAssetStore(rootDirectory: assetRoot),
            asset: asset,
            stringsProvider: { Strings.zhHans },
            visibleScreensProvider: { [self.screen] },
            tickInterval: 1.0 / 30.0,
            frameClock: clock,
            pointerLocationProvider: { pointer.location }
        )
        managers.append(manager)
        return (manager, pointer)
    }

    /// 覆盖测试用资产：idle 4 帧 @4fps + drag 2 帧 @8fps（悬停链）+ 可选 look。
    private func overlayAsset(lookFrames: [Int?] = Array(repeating: nil, count: 16)) -> PetSpriteAsset {
        var asset = PetSpriteAsset(
            id: "overlay-pet",
            displayName: "Overlay Pet",
            atlasFileName: "atlas.png",
            grid: PetSpriteAsset.Grid(columns: 8, rows: 9, cellWidth: 32, cellHeight: 32),
            animations: [
                PetSpriteAsset.Animation(id: PetAnimationID.idle, frames: [0, 1, 2, 3], fps: 4, loops: true, mirrorX: false),
                PetSpriteAsset.Animation(id: PetAnimationID.drag, frames: [32, 33], fps: 8, loops: true, mirrorX: false),
            ]
        )
        asset.lookFrames = lookFrames
        return asset
    }

    func test_pointerOutsideUpdatesLookDirectionEachTick() {
        let look = Array(repeating: nil, count: 16).withValue(4, 72)
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset(lookFrames: look))
        manager.start()
        // 首帧后把指针移到窗口右侧远处（窗口默认落在屏幕右下角内侧）。
        let rect = manager.windowController.panel!.frame
        pointer.location = CGPoint(x: rect.maxX + 200, y: rect.midY)

        manager.tick(delta: 1.0 / 30.0)

        XCTAssertEqual(manager.lookDirection, 4, "矩形外右侧 → 槽位 4")
        XCTAssertEqual(manager.displaySnapshot?.frameIndex, 72, "看向帧覆盖底层动画")
    }

    func test_pointerInsideIsDeadZone() {
        let look = Array(repeating: nil, count: 16).withValue(4, 72)
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset(lookFrames: look))
        manager.start()
        let rect = manager.windowController.panel!.frame
        pointer.location = CGPoint(x: rect.midX, y: rect.midY)

        manager.tick(delta: 1.0 / 30.0)

        XCTAssertNil(manager.lookDirection, "矩形内为死区")
        XCTAssertTrue((0...3).contains(manager.displaySnapshot?.frameIndex ?? -1), "回底层 idle（帧 0-3）")
    }

    func test_hoverTriggersOnceOnOutsideInsideEdge() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        let rect = manager.windowController.panel!.frame

        // 首次采样：建立外部基线（不触发）。
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertNil(manager.hoverPlayback, "首次采样只建基线")

        // 外→内边沿：触发一次性悬停。
        pointer.location = CGPoint(x: rect.midX, y: rect.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertEqual(manager.hoverPlayback?.animation.id, PetAnimationID.drag, "悬停用 drag 素材")
        XCTAssertEqual(manager.hoverPlayback?.animation.loops, false, "强制一次性播放")
        XCTAssertEqual(manager.behaviorState, .idle, "悬停不改底层行为态")

        // 播完（drag 2 帧 @8fps = 0.25s）后覆盖移除。
        manager.tick(delta: 0.3)
        XCTAssertNil(manager.hoverPlayback, "播完即移除覆盖")
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_hoverCooldownBlocksImmediateRetrigger() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        let rect = manager.windowController.panel!.frame
        let inside = CGPoint(x: rect.midX, y: rect.midY)

        // 触发一次。
        manager.tick(delta: 1.0 / 30.0)
        pointer.location = inside
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertNotNil(manager.hoverPlayback)

        // 离开再立即进入（< 2s）：冷却期内不重播。
        pointer.location = .zero
        manager.tick(delta: 0.3)
        pointer.location = inside
        manager.tick(delta: 0.1)
        XCTAssertNil(manager.hoverPlayback, "2s 冷却内不重触发")

        // 离开超过 2s 再进入：可再次触发。
        pointer.location = .zero
        manager.tick(delta: 3.0)
        pointer.location = inside
        manager.tick(delta: 0.1)
        XCTAssertNotNil(manager.hoverPlayback, "冷却结束可再次触发")
    }

    func test_hoverDoesNotClearReactionBubble() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        let rect = manager.windowController.panel!.frame
        _ = manager.submit(.celebrationTriggered(quotaLabel: "Claude 7d"))
        XCTAssertEqual(manager.behaviorState, .reaction(kind: .celebrate, resumeState: .idle))

        // 悬停触发：反应态与气泡保持（悬停只是渲染覆盖）。
        manager.tick(delta: 1.0 / 30.0)
        pointer.location = CGPoint(x: rect.midX, y: rect.midY)
        manager.tick(delta: 1.0 / 30.0)

        XCTAssertNotNil(manager.hoverPlayback)
        XCTAssertNotNil(manager.currentBubble, "悬停不清反应气泡")
        XCTAssertEqual(manager.behaviorState, .reaction(kind: .celebrate, resumeState: .idle))
    }

    func test_dragDisablesLookAndClearsHover() {
        let look = Array(repeating: nil, count: 16).withValue(4, 72)
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset(lookFrames: look))
        manager.start()
        let rect = manager.windowController.panel!.frame

        // 触发悬停后开始拖动：悬停清除、看向禁用。
        manager.tick(delta: 1.0 / 30.0)
        pointer.location = CGPoint(x: rect.midX, y: rect.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertNotNil(manager.hoverPlayback)

        manager.beginDrag()
        XCTAssertNil(manager.hoverPlayback, "开始直接拖动清除悬停覆盖")
        pointer.location = CGPoint(x: rect.maxX + 100, y: rect.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertNil(manager.lookDirection, "拖动期间看向禁用（不依赖指针位置假设）")
        XCTAssertTrue((32...33).contains(manager.displaySnapshot?.frameIndex ?? -1), "拖动显示 drag 动画（帧 32/33）")
    }

    func test_displaySnapshotPresentImmediatelyAfterStart() {
        let (manager, _) = makeOverlayManager(asset: overlayAsset())

        manager.start()

        XCTAssertTrue((0...3).contains(manager.displaySnapshot?.frameIndex ?? -1), "start 即产出首帧快照（首 tick 前不空白）")
        XCTAssertEqual(manager.displaySnapshot?.frameIndex, 0)
        XCTAssertEqual(manager.displaySnapshot?.size, manager.petSize)
    }

    // MARK: - 拖动方向与投掷（三期阶段②）

    /// 模拟一次快速右甩拖动：多次采样喂出速度后松手。
    private func flingRight(manager: DesktopPetManager, pointer: PointerBox, ticks: Int = 4) {
        manager.beginDrag()
        pointer.location = CGPoint(x: 600, y: 400)
        for index in 1...ticks {
            pointer.location = CGPoint(x: 600 + CGFloat(index) * 40, y: 400)
            manager.tick(delta: 0.02)
        }
        manager.endDrag()
    }

    func test_dragFacingUpdatesWithPointerDirection() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()

        manager.beginDrag()
        // 向左累计 5pt（一步达到阈值）：朝向换左。
        pointer.location = CGPoint(x: 500, y: 400)
        manager.tick(delta: 0.02)
        pointer.location = CGPoint(x: 495, y: 400)
        manager.tick(delta: 0.02)

        XCTAssertEqual(manager.dragFacing, .left, "拖动方向累计达到阈值后更新朝向")
        XCTAssertEqual(manager.behaviorState, .drag)
    }

    func test_releaseWithVelocityStartsMomentumKeepingDragState() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 600, y: 400)

        flingRight(manager: manager, pointer: pointer)

        XCTAssertTrue(manager.isMomentumActive, "快速松手应进入惯性运动")
        XCTAssertEqual(manager.behaviorState, .drag, "投掷视为 drag 的延续")
    }

    func test_stationaryReleaseEndsDragWithoutMomentum() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()

        manager.beginDrag()
        pointer.location = CGPoint(x: 500, y: 400)
        // 静止按住超过速度窗口。
        manager.tick(delta: 0.02)
        manager.tick(delta: 0.5)
        manager.endDrag()

        XCTAssertFalse(manager.isMomentumActive, "静止松手零速，不投掷")
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_momentumStepsWindowAndFinishesBackToIdle() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        // 窗口移到屏幕中部：右甩有飞行空间（默认落点贴右缘会立即反弹）。
        manager.windowController.move(to: CGPoint(x: 300, y: 400))
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer, ticks: 4)

        XCTAssertTrue(manager.isMomentumActive)
        let start = manager.windowController.currentOrigin?.x ?? 0

        // 推进若干步：窗口右移（摩擦衰减后自然结束回 idle）；反弹可能折返，取过程峰值。
        var maxX = start
        for _ in 0..<40 {
            manager.tick(delta: 1.0 / 30.0)
            maxX = max(maxX, manager.windowController.currentOrigin?.x ?? 0)
            if !manager.isMomentumActive { break }
        }

        XCTAssertFalse(manager.isMomentumActive, "摩擦衰减后投掷自然结束")
        XCTAssertEqual(manager.behaviorState, .idle)
        XCTAssertGreaterThan(maxX, start + 50, "投掷期间窗口沿初速方向明显移动")
    }

    func test_momentumDropsIncomingReactions() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)

        let accepted = manager.submit(.celebrationTriggered(quotaLabel: "Claude 7d"))

        XCTAssertFalse(accepted, "投掷期间反应丢弃不排队")
        XCTAssertNil(manager.currentBubble)
    }

    func test_newDragInterruptsMomentum() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)
        XCTAssertTrue(manager.isMomentumActive)

        // 投掷中开始新拖动：动量清除、以当前位置建新锚点。
        pointer.location = CGPoint(x: 400, y: 400)
        manager.beginDrag()

        XCTAssertFalse(manager.isMomentumActive)
        XCTAssertEqual(manager.behaviorState, .drag)
        // 旧投掷不再驱动窗口（新会话静止松手直接回 idle）。
        manager.tick(delta: 0.1)
        manager.endDrag()
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_singleClickInterruptsMomentumIntoPetted() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)
        XCTAssertTrue(manager.isMomentumActive)

        manager.pet()

        XCTAssertFalse(manager.isMomentumActive, "单击先结束投掷")
        XCTAssertEqual(manager.behaviorState, .petted(resumeState: .idle), "随后进入 petted")
    }

    func test_resetPositionInterruptsMomentum() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)

        manager.resetPosition()

        XCTAssertFalse(manager.isMomentumActive)
        XCTAssertEqual(manager.behaviorState, .idle)
        XCTAssertEqual(manager.windowController.currentOrigin?.y, screen.groundY)
    }

    func test_screenChangeInterruptsMomentumAndClamps() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)

        manager.handleScreenConfigurationChange()

        XCTAssertFalse(manager.isMomentumActive)
        XCTAssertEqual(manager.behaviorState, .idle)
    }

    func test_sizeChangeInterruptsMomentum() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)

        manager.setSize(.large)

        XCTAssertFalse(manager.isMomentumActive, "改尺寸取消投掷动量")
    }

    func test_teardownInterruptsMomentumAndLeavesNoResidue() {
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)

        manager.teardown()

        XCTAssertFalse(manager.isMomentumActive)
        XCTAssertNil(manager.windowController.panel)
    }

    func test_switchPetDuringMomentumDoesNotDriveNewWindow() throws {
        try installCustomPet(slug: "switch-target")
        let (manager, pointer) = makeOverlayManager(asset: overlayAsset())
        manager.start()
        pointer.location = CGPoint(x: 300, y: 400)
        flingRight(manager: manager, pointer: pointer)
        XCTAssertTrue(manager.isMomentumActive)

        manager.selectPet(slug: "switch-target")

        XCTAssertFalse(manager.isMomentumActive, "换宠先取消旧窗口动量")
        // 重建后的新窗口推进旧时钟：无残留运动（窗口静止）。
        let originAfterSwitch = manager.windowController.currentOrigin
        lastClock?.emit(delta: 0.1)
        XCTAssertEqual(
            manager.windowController.currentOrigin, originAfterSwitch,
            "旧投掷状态不得驱动新窗口"
        )
    }

    // MARK: - alpha 命中路由（三期阶段③）

    /// 构造左半实体资产的图集文件并注入搜索根（provider 需要真实图集才能裁帧）。
    private func installLeftHalfAtlasPet(slug: String) throws {
        let directory = assetRoot.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 2×1 网格 32×16：帧 0 内左半（x 0…8，即该格的一半）实体，右半透明。
        let columns = 2, rows = 1, cw = 16, chh = 16
        let width = columns * cw, height = rows * chh
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: cw / 2, height: chh))
        }
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let png = try XCTUnwrap(image.flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        })
        try png.write(to: directory.appendingPathComponent("atlas.png"))
        let manifest = #"""
        {
          "id": "\#(slug)",
          "name": "\#(slug)",
          "displayName": "\#(slug)",
          "atlas": "atlas.png",
          "grid": { "columns": 2, "rows": 1, "cellSize": [16, 16] },
          "animations": [{ "id": "idle", "frames": "0", "fps": 4, "loop": true }]
        }
        """#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
    }

    /// 以「库内左半实体资产」构造 Manager（图集从文件加载，命中层走真实裁剪链）。
    /// 需注入 `additionalSearchRoots` 让图集定位命中测试资产库（与生产 Bundle 路径对应）。
    private func makeLeftHalfPetManager() throws -> (manager: DesktopPetManager, pointer: PointerBox) {
        try installLeftHalfAtlasPet(slug: "left-half")
        // 图集定位搜索根：构造后 tick 期间须持续有效（tearDown 统一还原）。
        PetAssetLocator.additionalSearchRoots = [assetRoot]
        let clock = ManualFrameClock()
        frameClocks.append(clock)
        let pointer = PointerBox()
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: PetWindowController(petSize: CGSize(width: 96, height: 96)),
            assetStore: PetAssetStore(rootDirectory: assetRoot),
            stringsProvider: { Strings.zhHans },
            visibleScreensProvider: { [self.screen] },
            tickInterval: 1.0 / 30.0,
            frameClock: clock,
            pointerLocationProvider: { pointer.location }
        )
        managers.append(manager)
        // 裁剪缓存随资产库就位后再启动；selectPet 切到左半资产。
        manager.selectPet(slug: "left-half")
        return (manager, pointer)
    }

    func test_alphaRoutingPassesThroughTransparentHalf() throws {
        let (manager, pointer) = try makeLeftHalfPetManager()
        manager.start()
        // 窗口左半 = 实体（帧左半像素）；右半 = 透明。
        let frame = try XCTUnwrap(manager.windowController.panel?.frame)

        // 指针移到窗口右半（本地 x > 48）：未命中实体 → 穿透。
        pointer.location = CGPoint(x: frame.minX + 70, y: frame.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertFalse(
            manager.windowController.receivesMouseEvents,
            "透明半区窗口应穿透（事件到达下层应用）"
        )

        // 指针移到窗口左半：命中实体 → 接收。
        pointer.location = CGPoint(x: frame.minX + 20, y: frame.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertTrue(
            manager.windowController.receivesMouseEvents,
            "实体半区窗口应接收事件"
        )
    }

    func test_interactionLockOverridesAlphaRouting() throws {
        let (manager, pointer) = try makeLeftHalfPetManager()
        manager.start()
        let frame = try XCTUnwrap(manager.windowController.panel?.frame)
        // 指针在透明半区（路由判定穿透）。
        pointer.location = CGPoint(x: frame.minX + 70, y: frame.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertFalse(manager.windowController.receivesMouseEvents)

        // 按下锁定期（onInteractionLockStart）：即便指针在透明区也持续接收。
        manager.windowController.onInteractionLockStart?()
        pointer.location = CGPoint(x: frame.minX + 90, y: frame.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertTrue(
            manager.windowController.receivesMouseEvents,
            "交互锁期间穿透不得打开（按下后拖出实体区不丢会话）"
        )

        // 抬起解锁：立即重算命中恢复穿透。
        manager.windowController.onInteractionLockEnd?()
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertFalse(manager.windowController.receivesMouseEvents, "解锁后恢复按像素路由")
    }

    func test_dragSessionOverridesAlphaRouting() throws {
        let (manager, pointer) = try makeLeftHalfPetManager()
        manager.start()
        let frame = try XCTUnwrap(manager.windowController.panel?.frame)

        manager.beginDrag()
        pointer.location = CGPoint(x: frame.minX + 90, y: frame.midY)
        manager.tick(delta: 1.0 / 30.0)
        XCTAssertTrue(
            manager.windowController.receivesMouseEvents,
            "直接拖动期间窗口恒接收事件"
        )
        manager.endDrag()
    }

    func test_missingAssetPlaceholderKeepsRectHit() {
        // 缺资产：显示占位（矩形命中），窗口不得穿透成不可操作。
        let (manager, pointer) = makeOverlayManager(asset: nil)
        manager.start()
        let frame = manager.windowController.panel!.frame

        pointer.location = CGPoint(x: frame.minX + 90, y: frame.midY)
        manager.tick(delta: 1.0 / 30.0)

        XCTAssertTrue(
            manager.windowController.receivesMouseEvents,
            "缺资产可见占位保持矩形命中"
        )
    }
}

// MARK: - 测试辅助

private extension Array {
    /// 返回副本，将指定下标置为给定值（构造 16 槽位局部占用用）。
    func withValue(_ index: Int, _ value: Element) -> [Element] {
        var copy = self
        guard index >= 0, index < count else { return copy }
        copy[index] = value
        return copy
    }
}
