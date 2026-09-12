import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// 桌面宠物领域服务：窗口、行为循环、资产选择、位置 / 尺寸持久化。
/// 重接线 feature：install 时按 `petEnabled` 建窗并恢复状态，teardown 时窗口消失 + 循环停止。
@MainActor
final class DesktopPetManager: ObservableObject {
    /// 当前宠物状态（供视图渲染帧动画）。
    /// 离开反应态时自动清空气泡（自然结束 / 被打断 / 重置 / teardown 全覆盖）；
    /// 同级替换（reaction → reaction）不算离开，气泡文案由 `submit` 更新。
    @Published private(set) var behaviorState: PetBehaviorState = .idle {
        didSet {
            // 底层行为态切换即重置动画时间轴（覆盖层用独立时间轴，不触碰这里）。
            if oldValue != behaviorState {
                stateEnteredAtDisplay = displayDate
            }
            guard case .reaction = oldValue, currentBubble != nil else { return }
            if case .reaction = behaviorState { return }
            clearBubble()
        }
    }
    /// 当前反应气泡（nil = 无气泡；内容在反应开始时定格，期间不变）。
    @Published private(set) var currentBubble: PetBubbleContent?
    /// 当前尺寸档位。
    @Published private(set) var size: DesktopPetSize
    /// 当前宠物资产（nil 表示资产缺失，窗口显示占位）。
    @Published private(set) var asset: PetSpriteAsset?
    /// 当前选中的宠物 slug（内置宠物固定为 `PetAssetLocator.builtInPetID`）。
    @Published private(set) var selectedPetSlug: String
    /// 已安装社区宠物缓存（库内容变化时刷新，供视图即时更新）。
    @Published private(set) var installedPets: [PetAssetStore.InstalledPet] = []
    /// 社区宠物浏览器（清单与下载）。
    let community: PetCommunityBrowser

    /// 无帧时钟驱动时的固定推进步长（秒）；测试注入更长间隔避免时序抖动。
    private let tickInterval: TimeInterval
    /// 位置持久化防抖间隔。
    private let persistDebounce: TimeInterval
    /// 注入的帧时钟；nil 时使用默认 `DisplayLinkFrameClock`。
    private let injectedFrameClock: PetFrameClock?

    private let userDefaults: UserDefaults
    /// 窗口控制器（测试断言窗口生命周期与位置用；外部不应直接改窗口状态）。
    let windowController: PetWindowController
    /// 对话气泡子窗控制器（随反应态展示 / 收起；测试断言气泡面板用）。
    private(set) var bubbleController: PetBubbleWindowController
    /// 气泡文案变体掷点（0..<1；测试钉死保证确定性）。
    private let bubbleVariantRoll: () -> Double
    private let engine: PetBehaviorEngine
    private let assetStore: PetAssetStore
    private let visibleScreensProvider: () -> [PetScreenGeometry]
    private let stringsProvider: () -> Strings
    /// 打开设置页回调（组合根接线）。
    var openSettingsHandler: (() -> Void)?

    /// 事件协调器与订阅（二期反应联动；随 start/teardown 启停，开关切换走 `syncReactions` 增量同步）。
    /// 内部可写供测试断言订阅的即时增减，外部不应触碰。
    private(set) var reactionCoordinator: PetEventCoordinator?
    private var reactionCancellables: Set<AnyCancellable> = []
    /// 屏幕配置变更监听（拔屏 / 改分辨率时夹回可见区）。
    private var screenChangeObserver: NSObjectProtocol?

    /// 当前帧时钟（首次启动时解析，start / stop 之间复用同一实例）。
    private var frameClock: PetFrameClock?
    /// 行为循环是否在运行（原 `tickTask != nil` 的等价判据）。
    private var isRunning = false
    private var persistTask: Task<Void, Never>?
    private var decisionRemaining: TimeInterval = 0
    /// 窗口拖动监听：拖拽中不跑行为循环，松手后按落地状态恢复。
    private var isDragging = false
    /// 行走活动锚点（宠物左下角 x）：拖拽松手 / 重置位置 / 屏幕夹回时更新，
    /// 宠物只在锚点左右 `walkRadius` 范围内活动，不会满屏乱走。
    private var walkAnchorX: CGFloat?
    /// 被一次性状态（抚摸 / 反应）打断的自主行为剩余时长；恢复自主态时归还，避免打断吞时长。
    private var interruptedRemaining: TimeInterval?

    /// 行走活动半径（点）：以锚点为中心的水平活动半宽。
    private let walkRadius: CGFloat = 120

    /// 进行中的投掷（nil = 无惯性运动）。投掷视为 drag 的延续：
    /// 反应丢弃、自主掷骰暂停、看向与悬停禁用、气泡维持拖动开始即清。
    private var momentum: (position: CGPoint, velocity: CGVector)?
    /// 投掷开始至今的真实单调历时（秒；不累加被钳制的 dt）。
    private var momentumElapsed: TimeInterval = 0
    /// 拖动方向与速度采样器（消费统一指针采样流）。
    private var dragMotion = PetDragMotionTracker()

    /// 投掷（松手后惯性运动）是否进行中。
    var isMomentumActive: Bool { momentum != nil }

    // MARK: - 指针采样与显示覆盖（三期：看向 / 悬停 / 统一显示快照）

    /// 指针位置采样源（AppKit 屏幕坐标）；测试注入固定序列。
    private let pointerLocationProvider: () -> CGPoint
    /// 显示时钟：由 tick delta 推进的虚拟挂钟（循环相位连续、测试确定）。
    private var displayDate = Date(timeIntervalSinceReferenceDate: 0)
    /// 当前底层行为态的进入时刻（显示时钟域；覆盖不重置它，底层逻辑照常推进）。
    private var stateEnteredAtDisplay = Date(timeIntervalSinceReferenceDate: 0)
    /// 指针是否在宠物矩形内的上一次采样值（nil = 首次采样只建基线，不触发悬停）。
    private var pointerInsideBaseline: Bool?
    /// 悬停一次性播放（nil = 无覆盖）。
    private(set) var hoverPlayback: PetHoverPlayback?
    /// 悬停冷却截止时刻（显示时钟域；触发后至少 2s 才能再次触发）。
    private var hoverCooldownUntil = Date.distantPast
    /// 当前看向方向槽位（矩形外才有；拖动 / 投掷期间为 nil）。
    private(set) var lookDirection: Int?
    /// 最终显示快照（渲染与命中共享的唯一帧真相；非 Published——由视图帧时钟轮询读取，
    /// 避免 30Hz 帧更新惊动所有订阅 Manager 的页面视图）。
    private(set) var displaySnapshot: PetDisplaySnapshot?
    /// 直接拖动期间的手势水平朝向（阶段②驱动分向走动表现；非拖动为 nil）。
    private(set) var dragFacing: PetDirection?

    init(
        userDefaults: UserDefaults = .standard,
        windowController: PetWindowController? = nil,
        engine: PetBehaviorEngine? = nil,
        assetStore: PetAssetStore? = nil,
        community: PetCommunityBrowser? = nil,
        asset: PetSpriteAsset? = nil,
        tuning: PetBehaviorTuning? = nil,
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s },
        visibleScreensProvider: (() -> [PetScreenGeometry])? = nil,
        tickInterval: TimeInterval = 1.0 / 30.0,
        persistDebounce: TimeInterval = 0.5,
        frameClock: PetFrameClock? = nil,
        bubbleController: PetBubbleWindowController? = nil,
        bubbleVariantRoll: @escaping () -> Double = { Double.random(in: 0..<1) },
        pointerLocationProvider: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.userDefaults = userDefaults
        self.stringsProvider = stringsProvider
        self.visibleScreensProvider = visibleScreensProvider ?? { PetWindowController.screenGeometries() }
        let resolvedTuning = tuning ?? Self.storedTuning(userDefaults: userDefaults)
        // 调参统一由下方 apply 注入（含注入 engine 的场景），构造处不再重复传。
        self.engine = engine ?? PetBehaviorEngine()
        self.engine.apply(tuning: resolvedTuning)
        self.tickInterval = tickInterval
        self.persistDebounce = persistDebounce
        self.injectedFrameClock = frameClock
        let store = assetStore ?? PetAssetStore(rootDirectory: PetAssetStore.defaultRootDirectory())
        self.assetStore = store
        self.community = community ?? PetCommunityBrowser(store: store)

        let resolvedSize = DesktopPetSize.from(userDefaults.integer(forKey: UserDefaultsKeys.petSize))
        self.size = resolvedSize

        let storedSlug = userDefaults.string(forKey: UserDefaultsKeys.petSelectedSlug)
        let slug = Self.normalizedSelectedSlug(stored: storedSlug, store: store)
        // 规范化后与存储值不同（旧 cat 迁移 / 失效选择回退）时同步落盘，
        // 保证选中态与实际画面一致（重启后不反复迁移）。
        if slug != storedSlug {
            userDefaults.set(slug, forKey: UserDefaultsKeys.petSelectedSlug)
        }
        self.selectedPetSlug = slug
        let resolvedAsset = asset ?? Self.resolveAsset(slug: slug, store: store)
        self.asset = resolvedAsset
        self.windowController = windowController
            ?? PetWindowController(petSize: Self.petSize(for: resolvedSize, asset: resolvedAsset))
        self.bubbleController = bubbleController ?? PetBubbleWindowController()
        self.bubbleVariantRoll = bubbleVariantRoll
        self.pointerLocationProvider = pointerLocationProvider
        self.installedPets = store.installedPets()
        // 拖动由窗口承载的原生拖动会话驱动（越过阈值才触发），此处接线状态迁移回调。
        self.windowController.onWindowDragStart = { [weak self] in self?.beginDrag() }
        self.windowController.onWindowDragEnd = { [weak self] in self?.endDrag() }
    }

    // MARK: - 生命周期

    /// 功能启用：建窗、恢复位置与偏好、启动行为循环。
    /// 已在运行时（如反应开关切换触发的 sync 重入）：只做反应联动增量同步，不重建窗口。
    func start() {
        guard !isRunning else {
            syncReactions()
            return
        }
        behaviorState = .idle
        engine.resetToIdle()
        engine.drainExternalEvents()
        // 启动先安静停留一段采样时长，再进入矩阵决策（与其他硬切回 idle 路径同口径）。
        decisionRemaining = engine.sampleDuration(for: .idle)
        let origin = restoredOrigin()
        // 恢复位置即初始活动锚点，重启后不会跑到别处。
        walkAnchorX = origin?.x
        windowController.apply(petSize: petSize)
        windowController.show(
            initialOrigin: origin,
            rootView: PetSpriteView(manager: self, asset: asset)
        )
        // 重置覆盖与采样基线（新会话从零开始），并立即产出首帧快照（首 tick 前不空白）。
        pointerInsideBaseline = nil
        hoverPlayback = nil
        hoverCooldownUntil = .distantPast
        lookDirection = nil
        stateEnteredAtDisplay = displayDate
        updateDisplaySnapshot()
        startFrameClock()
        startReactionCoordinator()
        installScreenChangeObserver()
    }

    /// 功能停用 / 卸载 / App 退出：窗口立即消失并停止所有定时器。
    func teardown() {
        // 先停帧时钟再关窗：时钟绑定在窗口 contentView 上，顺序颠倒会残留回调。
        stopFrameClock()
        persistTask?.cancel()
        persistTask = nil
        // 关窗前把当前位置落盘（停用 / 换宠 / 退出都经此），下次启动恢复不失真。
        persistPositionNow()
        decisionRemaining = 0
        interruptedRemaining = nil
        isDragging = false
        walkAnchorX = nil
        behaviorState = .idle
        // 覆盖与采样状态一并清理：停用后不留指针基线 / 悬停时间戳 / 快照引用。
        pointerInsideBaseline = nil
        hoverPlayback = nil
        hoverCooldownUntil = .distantPast
        lookDirection = nil
        dragFacing = nil
        displaySnapshot = nil
        // 投掷动量与交互锁一并清除；关窗前已 persistPositionNow 落盘当前位置。
        momentum = nil
        momentumElapsed = 0
        engine.drainExternalEvents()
        stopReactionCoordinator()
        removeScreenChangeObserver()
        bubbleController.close()
        windowController.close()
    }

    // MARK: - 偏好与资产

    /// 当前语言字符串（视图层取文案用）。
    var strings: Strings { stringsProvider() }

    /// 当前宠物窗口尺寸（高度 = 档位尺寸，宽度按素材宽高比）。
    var petSize: CGSize { Self.petSize(for: size, asset: asset) }

    /// 当前是否使用自定义（社区）宠物。
    var isCustomPet: Bool { selectedPetSlug != PetAssetLocator.builtInPetID }

    /// 可选择的宠物：内置 + 已安装社区宠物。
    var availablePets: [PetAssetStore.InstalledPet] {
        var list: [PetAssetStore.InstalledPet] = [
            PetAssetStore.InstalledPet(
                slug: PetAssetLocator.builtInPetID,
                displayName: strings.desktopPetBuiltIn
            ),
        ]
        list.append(contentsOf: installedPets.filter {
            $0.slug != PetAssetLocator.builtInPetID
        })
        return list
    }

    /// 重新读取宠物库内容（导入 / 下载 / 删除后调用）。
    func refreshInstalledPets() {
        installedPets = assetStore.installedPets()
    }

    /// 切换尺寸档位并持久化。改尺寸先取消投掷，保持左下角再夹回可见屏。
    func setSize(_ newSize: DesktopPetSize) {
        guard newSize != size else { return }
        cancelMomentum(anchorCurrent: true)
        size = newSize
        userDefaults.set(newSize.rawValue, forKey: UserDefaultsKeys.petSize)
        windowController.apply(petSize: petSize)
        // 尺寸变化同步命中判定与显示快照。
        updateDisplaySnapshot()
    }

    /// 素材可支撑的自主态集合（缺素材的行为从矩阵剔除，防僵着滑行）。
    static func availableAutonomyKinds(for asset: PetSpriteAsset?) -> Set<PetAutonomyKind> {
        var kinds: Set<PetAutonomyKind> = [.idle, .walkLeft, .walkRight]
        // 玩耍复用挥手（抚摸）素材；蹦跳复用悬空素材。
        if asset?.animation(id: PetAnimationID.petted) != nil {
            kinds.insert(.frolic)
        }
        if asset?.animation(id: PetAnimationID.drag) != nil
            || asset?.animation(id: PetAnimationID.fall) != nil {
            kinds.insert(.hop)
        }
        return kinds
    }

    /// 按当前资产收缩矩阵（换宠 / 启动后调用）。
    func syncAutonomyAvailability() {
        engine.apply(availableKinds: Self.availableAutonomyKinds(for: asset))
    }

    /// 切换当前宠物：解析资产并（若在运行）重建窗口以应用新尺寸。
    /// 覆盖状态先清理——旧宠物的悬停时间戳 / 看向帧 / 动量不得驱动新窗口。
    func selectPet(slug: String) {
        selectedPetSlug = slug
        userDefaults.set(slug, forKey: UserDefaultsKeys.petSelectedSlug)
        asset = Self.resolveAsset(slug: slug, store: assetStore)
        engine.apply(availableKinds: Self.availableAutonomyKinds(for: asset))
        pointerInsideBaseline = nil
        hoverPlayback = nil
        hoverCooldownUntil = .distantPast
        lookDirection = nil
        cancelMomentum(anchorCurrent: false)
        restartIfRunning()
    }

    /// 导入社区宠物目录并切换为当前宠物。
    @discardableResult
    func importPet(from source: URL) throws -> PetAssetStore.InstalledPet {
        let pet = try assetStore.importPet(from: source)
        invalidateSpriteCache()
        refreshInstalledPets()
        selectPet(slug: pet.slug)
        return pet
    }

    /// 从社区清单下载宠物、入库并切换为当前宠物。
    @discardableResult
    func downloadCommunityPet(_ pet: PetdexPet) async -> Result<PetAssetStore.InstalledPet, Error> {
        let result = await community.download(pet)
        if case .success(let installed) = result {
            invalidateSpriteCache()
            refreshInstalledPets()
            selectPet(slug: installed.slug)
        }
        return result
    }

    /// 按名字安装社区宠物（在 petdex 网站上看中后回来输入名字）。
    @discardableResult
    func installCommunityPet(byName name: String) async -> Result<PetAssetStore.InstalledPet, Error> {
        let result = await community.install(byName: name)
        if case .success(let installed) = result {
            invalidateSpriteCache()
            refreshInstalledPets()
            selectPet(slug: installed.slug)
        }
        return result
    }

    /// 删除已安装的社区宠物；若正被使用则切回内置。
    func removePet(slug: String) throws {
        guard slug != PetAssetLocator.builtInPetID else { return }
        try assetStore.remove(slug: slug)
        invalidateSpriteCache()
        refreshInstalledPets()
        if selectedPetSlug == slug {
            selectPet(slug: PetAssetLocator.builtInPetID)
        }
    }

    /// 当前好动程度档位。
    var activityPreset: PetBehaviorTuning.ActivityPreset {
        PetBehaviorTuning.ActivityPreset(
            rawValue: userDefaults.string(forKey: UserDefaultsKeys.petActivityLevel) ?? ""
        ) ?? .balanced
    }

    /// 切换好动程度档位并立即生效。
    func setActivityPreset(_ preset: PetBehaviorTuning.ActivityPreset) {
        userDefaults.set(preset.rawValue, forKey: UserDefaultsKeys.petActivityLevel)
        var tuning = Self.storedTuning(userDefaults: userDefaults)
        tuning.activityLevel = preset.activityLevel
        engine.apply(tuning: tuning)
    }

    /// 从持久化构造调参（非法值回退默认档）。
    static func storedTuning(userDefaults: UserDefaults) -> PetBehaviorTuning {
        var tuning = PetBehaviorTuning.default
        let preset = PetBehaviorTuning.ActivityPreset(
            rawValue: userDefaults.string(forKey: UserDefaultsKeys.petActivityLevel) ?? ""
        ) ?? .balanced
        tuning.activityLevel = preset.activityLevel
        return tuning
    }

    /// 重置到所在屏默认位置（右侧地面）。先取消投掷动量再重置位置、锚点与 idle。
    func resetPosition() {
        cancelMomentum(anchorCurrent: false)
        let screens = visibleScreensProvider()
        guard let screen = PetPositionPlanner.screenContaining(
            position: windowController.currentOrigin ?? .zero,
            petSize: petSize,
            screens: screens
        ) ?? screens.first else { return }
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - petSize.width - 40,
            y: screen.groundY
        )
        windowController.move(to: origin)
        walkAnchorX = origin.x
        persistPositionDebounced()
        engine.resetToIdle()
        behaviorState = .idle
        decisionRemaining = engine.sampleDuration(for: .idle)
        interruptedRemaining = nil
        hoverPlayback = nil
        updateDisplaySnapshot()
    }

    // MARK: - 行为循环

    /// 启动行为循环：在宠物视图上挂帧时钟，按真实帧间隔推进。
    /// 视图离屏 / 隐藏时原生时钟自动挂起（零空转功耗）。
    private func startFrameClock() {
        guard let view = windowController.panel?.contentView else { return }
        let clock = frameClock ?? injectedFrameClock ?? DisplayLinkFrameClock()
        clock.onTick = { [weak self] delta in
            self?.tick(delta: delta)
        }
        clock.start(in: view)
        frameClock = clock
        isRunning = true
    }

    /// 停止行为循环：清空回调并解除时钟对视图 / runloop 的持有。
    private func stopFrameClock() {
        frameClock?.onTick = nil
        frameClock?.stop()
        isRunning = false
    }

    /// 单次行为推进：按当前状态驱动位移与状态转移。
    /// - Parameter delta: 距上一帧的秒数；nil 时回退到固定步长 `tickInterval`（无时钟驱动 / 测试）。
    func tick(delta: TimeInterval? = nil) {
        // 窗口已消失（teardown 后）时自愈停表，避免残留时钟空转。
        guard windowController.panel != nil else {
            stopFrameClock()
            return
        }
        let dt = delta ?? tickInterval
        // 显示时钟统一推进（覆盖与底层动画共用同一时间轴原点域）。
        displayDate = displayDate.addingTimeInterval(dt)
        // 指针采样先于拖动 / 行为推进：拖动方向与速度（阶段②）同样依赖采样流。
        // 原生拖动会话期间 runloop 走 .eventTracking，帧时钟注册在 .common 仍持续回调。
        samplePointerOverlays()
        // 投掷步进先于直接拖动暂停与普通行为（SPEC 5.4 顺序）。
        if let current = momentum {
            stepMomentum(current: current, delta: dt)
            updateDisplaySnapshot()
            return
        }
        guard !isDragging else {
            updateDisplaySnapshot()
            return
        }
        let currentPetSize = petSize
        let screens = visibleScreensProvider()
        guard let origin = windowController.currentOrigin,
              let screen = PetPositionPlanner.screenContaining(
                position: origin,
                petSize: currentPetSize,
                screens: screens
              ) ?? screens.first else {
            updateDisplaySnapshot()
            return
        }

        switch behaviorState {
        case .idle, .frolic, .hop:
            decisionRemaining -= dt
            if decisionRemaining <= 0 {
                // 矩阵决策：idle 与 walk 行分布不同（行走后更倾向回归 idle）；
                // 玩耍/蹦跳是一次性自主小动作，播完同样回到矩阵重新掷骰。
                let decision = engine.nextAutonomousDecision()
                engine.apply(decision)
                decisionRemaining = autonomyDuration(for: decision)
                behaviorState = decision.state
            }

        case .walk(let direction):
            decisionRemaining -= dt
            // walkDelta 已含方向符号，位置规划需要正数步长。
            let anchorX = walkAnchorX ?? origin.x
            let range = PetPositionPlanner.walkRange(
                anchorX: anchorX,
                radius: walkRadius,
                petSize: currentPetSize,
                screen: screen
            )
            let step = PetPositionPlanner.stepWalk(
                position: origin,
                direction: direction,
                distance: abs(engine.walkDelta(dt: dt)),
                walkRange: range
            )
            windowController.move(to: step.position)
            // 位置持久化只在离散转换点（转身 / 行走结束）落盘，避免每帧调度防抖任务。
            // 边缘转身后方向改变，需同步状态。
            if step.direction != direction {
                engine.apply(PetBehaviorDecision(
                    state: .walk(direction: step.direction),
                    horizontalDelta: 0,
                    duration: max(decisionRemaining, 0.5)
                ))
                behaviorState = .walk(direction: step.direction)
                persistPositionDebounced()
            } else if decisionRemaining <= 0 {
                engine.apply(PetBehaviorDecision(state: .idle, horizontalDelta: 0, duration: 0))
                behaviorState = .idle
                // 行走结束是硬切回 idle：必须重新采样停留时长。若沿用归零的计时器，
                // idle 会在下一帧立即到期重掷（45% 概率直接又走/玩/跳），
                // 观感为「走完不停、一直重复走动」。
                decisionRemaining = engine.sampleDuration(for: .idle)
                persistPositionDebounced()
            }

        case .drag:
            // 拖拽期间位置由 AppKit 窗口拖动接管，循环只等状态变化。
            break

        case .petted:
            decisionRemaining -= dt
            if decisionRemaining <= 0 {
                engine.finishPetted()
                behaviorState = engine.state
                decisionRemaining = interruptedRemaining ?? engine.sampleDuration(for: .idle)
                interruptedRemaining = nil
            }

        case .reaction(let kind, _):
            // 反应期间自主层挂起：只倒计时，不位移不掷骰。
            decisionRemaining -= dt
            if decisionRemaining <= 0 {
                engine.finishReaction()
                behaviorState = engine.state
                decisionRemaining = interruptedRemaining ?? engine.sampleDuration(for: .idle)
                interruptedRemaining = nil
            }
            _ = kind
        }

        updateDisplaySnapshot()
    }

    // MARK: - 指针采样与显示覆盖

    /// 统一指针采样（每 tick 一次，约 30Hz）：更新看向方向并驱动悬停的外→内边沿。
    /// 隐藏 / 停用时 tick 不跑，采样自然停止；重新显示后首次采样只建立基线。
    private func samplePointerOverlays() {
        guard let panel = windowController.panel else { return }
        let pointer = pointerLocationProvider()
        let petRect = panel.frame
        let inside = Self.pointer(pointer, isInRect: petRect)

        // 直接拖动期间：喂方向 / 速度采样器（指针位移即窗口位移，会话锚点固定）。
        if isDragging {
            if dragMotion.update(
                pointer: pointer,
                at: displayDate.timeIntervalSinceReferenceDate
            ) {
                dragFacing = dragMotion.facing
                updateDisplaySnapshot()
            }
        }

        // 看向：直接拖动 / 投掷期间显式禁用（不能依赖「指针必在矩形内」的假设）；
        // 矩形内（含边界）为死区。方向缺帧的回退在显示解析层处理。
        lookDirection = (isDragging || isMomentumActive)
            ? nil
            : PetLookOverlay.directionIndex(pointer: pointer, petRect: petRect)

        // 悬停：首次采样只建基线；外→内边沿触发，内→外离开即清除。
        if let baseline = pointerInsideBaseline {
            if inside && !baseline {
                tryStartHover()
            } else if !inside {
                hoverPlayback = nil
            }
        }
        pointerInsideBaseline = inside
    }

    /// 触发一次悬停覆盖：素材链 drag → fall，一次性播放；无素材则不显示覆盖。
    /// 不修改底层行为态 / 计时 / 气泡；触发后至少 2s 冷却，持续停留不重播（边沿触发）。
    private func tryStartHover() {
        guard !isDragging, !isMomentumActive else { return }
        guard displayDate >= hoverCooldownUntil else { return }
        guard let animation = asset?.animation(id: PetAnimationID.drag)
            ?? asset?.animation(id: PetAnimationID.fall) else { return }
        hoverPlayback = PetHoverPlayback(animation: animation.oneShot(), startedAt: displayDate)
        hoverCooldownUntil = displayDate.addingTimeInterval(2)
    }

    /// 重算最终显示快照：渲染与命中共享的唯一帧真相。
    private func updateDisplaySnapshot() {
        // 悬停播完即移除覆盖（下一层解析自然回落到底层动画）。
        if let hover = hoverPlayback, hover.isFinished(at: displayDate) {
            hoverPlayback = nil
        }
        guard let asset else {
            displaySnapshot = nil
            return
        }
        guard let resolution = PetDisplayResolver.resolve(
            state: behaviorState,
            asset: asset,
            dragFacing: dragFacing,
            lookDirection: lookDirection,
            hover: hoverPlayback,
            now: displayDate,
            stateEnteredAt: stateEnteredAtDisplay
        ) else {
            displaySnapshot = nil
            return
        }
        displaySnapshot = PetDisplaySnapshot(
            asset: asset,
            frameIndex: resolution.frameIndex,
            mirrored: resolution.mirrored,
            size: petSize
        )
    }

    /// 指针是否在矩形内（含边界；与 `PetLookOverlay` 的死区判定同口径）。
    static func pointer(_ pointer: CGPoint, isInRect rect: CGRect) -> Bool {
        pointer.x >= rect.minX && pointer.x <= rect.maxX
            && pointer.y >= rect.minY && pointer.y <= rect.maxY
    }

    // MARK: - 交互

    /// 单击抚摸。已在抚摸中再次点击视为连击：延长抚摸时长（引擎态不变，仅重置计时）。
    /// 投掷进行中先结束投掷（以当前位置建立活动锚点），再进入 petted。
    func pet() {
        if isMomentumActive {
            cancelMomentum(anchorCurrent: true)
            engine.endDrag()
        }
        captureInterruptedRemaining()
        engine.pet()
        guard case .petted = engine.state else { return }
        behaviorState = engine.state
        // 抚摸动画时长由资产定义，缺资产时给一个保守值。
        decisionRemaining = oneShotDuration(ids: [PetAnimationID.petted], fallback: 0.6)
        updateDisplaySnapshot()
    }

    /// 拖拽开始：进入拖动状态，位移随后由系统原生窗口拖动会话接管。
    /// 看向与悬停覆盖立即禁用 / 清除（气泡沿用拖动开始即清的既有语义）。
    /// 投掷进行中开始新拖动：清除投掷速度 / 样本，以当前位置建立新锚点，
    /// 不运行旧投掷完成回调。
    func beginDrag() {
        if isMomentumActive {
            momentum = nil
            momentumElapsed = 0
            walkAnchorX = windowController.currentOrigin?.x
        }
        isDragging = true
        dragMotion.reset()
        dragFacing = nil
        hoverPlayback = nil
        lookDirection = nil
        engine.beginDrag()
        behaviorState = .drag
        updateDisplaySnapshot()
    }

    /// 拖拽结束：有投掷初速则延续 drag 进入惯性运动；否则悬停在松手处回 idle，
    /// 松手处成为新的行走活动锚点。
    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        // 松手速度：补录最终样本后取 80ms 窗口首末差分（静止松手自然为零速）。
        let releaseVelocity = dragMotion.velocity(
            at: displayDate.timeIntervalSinceReferenceDate,
            location: pointerLocationProvider()
        )
        dragFacing = nil
        // 指针此刻必在宠物附近：重建悬停基线，避免松手后一次假边沿触发跳跃。
        pointerInsideBaseline = true
        // 以松手处为活动锚点：之后只在附近走动，不再满屏游走。
        walkAnchorX = windowController.currentOrigin?.x
        if let origin = windowController.currentOrigin,
           hypot(releaseVelocity.dx, releaseVelocity.dy) >= PetThrowPhysics.stopSpeed {
            // 投掷视为 drag 的延续：保持 drag 行为态，物理步进在 tick 中推进。
            momentum = (position: origin, velocity: releaseVelocity)
            momentumElapsed = 0
            // 投掷表现按初速水平符号给分向走动；纯竖直投掷无朝向（悬空姿态）。
            if abs(releaseVelocity.dx) > 1 {
                dragFacing = releaseVelocity.dx > 0 ? .right : .left
            }
            persistPositionDebounced()
            updateDisplaySnapshot()
            return
        }
        engine.endDrag()
        behaviorState = engine.state
        decisionRemaining = engine.sampleDuration(for: .idle)
        interruptedRemaining = nil
        persistPositionDebounced()
        updateDisplaySnapshot()
    }

    // MARK: - 投掷步进（SPEC 5.4）

    /// 推进一步投掷物理：真实历时计入、按连续路径碰撞、摩擦衰减；
    /// 自然结束时统一收尾（回 idle、采样停留时长、清打断剩余、更新锚点并持久化）。
    private func stepMomentum(current: (position: CGPoint, velocity: CGVector), delta: TimeInterval) {
        momentumElapsed += delta
        let result = PetThrowPhysics.step(
            position: windowController.currentOrigin ?? current.position,
            velocity: current.velocity,
            elapsed: momentumElapsed,
            delta: delta,
            petSize: petSize,
            screens: visibleScreensProvider()
        )
        windowController.move(to: result.position)
        if result.finished {
            finishMomentum(at: result.position)
        } else {
            momentum = (position: result.position, velocity: result.velocity)
        }
    }

    /// 投掷自然结束的统一收尾路径。
    private func finishMomentum(at position: CGPoint) {
        momentum = nil
        momentumElapsed = 0
        dragFacing = nil
        engine.endDrag()
        behaviorState = engine.state
        decisionRemaining = engine.sampleDuration(for: .idle)
        interruptedRemaining = nil
        walkAnchorX = position.x
        persistPositionDebounced()
    }

    /// 取消投掷（中断表通用收尾）：清除动量与朝向；不运行自然结束回调。
    /// `anchorCurrent` = true 时以当前位置更新活动锚点（单击抚摸等就地交互场景）。
    private func cancelMomentum(anchorCurrent: Bool = true) {
        guard isMomentumActive else { return }
        momentum = nil
        momentumElapsed = 0
        dragFacing = nil
        if anchorCurrent {
            walkAnchorX = windowController.currentOrigin?.x
        }
    }

    /// 显示器配置变更：取消投掷动量后夹回可见区并回到 idle。
    /// 夹回用与 tick 同源的 `visibleScreensProvider`（单一几何口径）；
    /// 夹回后的落点即新活动锚点（旧屏坐标在新屏上已无意义）。
    func handleScreenConfigurationChange() {
        cancelMomentum(anchorCurrent: false)
        guard let origin = windowController.currentOrigin else { return }
        let screens = visibleScreensProvider()
        guard let screen = PetPositionPlanner.screenContaining(
            position: origin,
            petSize: petSize,
            screens: screens
        ) ?? screens.first else { return }
        let clamped = PetPositionPlanner.clamp(origin, petSize: petSize, to: screen)
        windowController.move(to: clamped)
        walkAnchorX = clamped.x
        engine.resetToIdle()
        behaviorState = .idle
        decisionRemaining = engine.sampleDuration(for: .idle)
        interruptedRemaining = nil
        hoverPlayback = nil
        persistPositionDebounced()
        updateDisplaySnapshot()
    }

    // MARK: - 事件反应联动（二期）

    /// 状态反应总开关（默认开）。
    var isReactionsEnabled: Bool {
        userDefaults.bool(forKey: UserDefaultsKeys.petReactionsEnabled)
    }

    /// 反应联动总开关切换后的增量同步（幂等）：开→补订阅与 CPU 采样激活源，关→全撤。
    /// 供 `start()` 在已运行分支与设置页 Toggle 的手动 sync 调用。
    func syncReactions() {
        guard isRunning else { return }
        if isReactionsEnabled {
            startReactionCoordinator()
        } else {
            stopReactionCoordinator()
        }
    }

    /// 启动反应联动：订阅四源 + 重置多播，并激活 CPU 采样。
    /// 门控：宠物已启用（start 才会走到这）且总开关开。
    private func startReactionCoordinator() {
        guard reactionCoordinator == nil, isReactionsEnabled else { return }
        let coordinator = PetEventCoordinator { [weak self] event in
            self?.submit(event) ?? false
        }
        reactionCoordinator = coordinator

        // CPU：订阅监控快照（快照常驻 0…1，换算 0…100）。
        if let monitor = FeatureRuntime.shared.manager(for: .systemMonitor, as: SystemMonitorManager.self) {
            monitor.petReactionDemand = true
            monitor.$snapshot
                .receive(on: RunLoop.main)
                .sink { [weak coordinator] snapshot in
                    coordinator?.handleCPUSample(percent: (snapshot.cpuUsage?.total ?? 0) * 100)
                }
                .store(in: &reactionCancellables)
        }

        // 限额：与重置检测同口径拍平（含带标签窗口），取最紧张窗口的剩余百分比
        // 与「平台 + 窗口」标签喂下降沿判定；重置多播喂庆祝（标签组合同 toast 口径）。
        if let token = FeatureRuntime.shared.manager(for: .tokenUsage, as: TokenUsageManager.self) {
            token.$limits
                .receive(on: RunLoop.main)
                .sink { [weak coordinator, weak self] limits in
                    guard let self else { return }
                    let readings = limits.limitResetReadings(strings: self.strings)
                    let minReading = readings.min {
                        (100 - $0.usedPercent) < (100 - $1.usedPercent)
                    }
                    coordinator?.handleLimitsUpdate(
                        shortagePercent: minReading.map { 100 - $0.usedPercent },
                        quotaLabel: minReading
                            .map { "\($0.provider.displayName) \($0.windowLabel)" }
                            ?? ""
                    )
                }
                .store(in: &reactionCancellables)
            token.addLimitResetObserver { [weak coordinator] event, _, _ in
                coordinator?.handleLimitReset(
                    quotaLabel: "\(event.provider.displayName) \(event.windowLabel)"
                )
            }
        }

        // 剪贴板：首条目出现新 id 且时间戳更新视为新复制。
        // （条目数判据有盲区：达上限去旧不增计数；清空历史会误判为增加。）
        if let clipboard = FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self) {
            clipboard.$entries
                .receive(on: RunLoop.main)
                .sink { [weak coordinator] entries in
                    coordinator?.handleClipboardHead(
                        id: entries.first?.id,
                        createdAt: entries.first?.createdAt
                    )
                }
                .store(in: &reactionCancellables)
        }

        // 输入法锁定边沿。
        if let lock = FeatureRuntime.shared.manager(for: .inputLock, as: LockStateManager.self) {
            lock.$isLocked
                .receive(on: RunLoop.main)
                .sink { [weak coordinator] locked in
                    coordinator?.handleInputLock(locked: locked)
                }
                .store(in: &reactionCancellables)
        }
    }

    /// 停止反应联动：撤全部订阅与 CPU 采样激活源（可插拔契约）。
    private func stopReactionCoordinator() {
        reactionCancellables.removeAll()
        reactionCoordinator = nil
        FeatureRuntime.shared.manager(for: .systemMonitor, as: SystemMonitorManager.self)?
            .petReactionDemand = false
    }

    // MARK: - 二期事件入口（形状锁定）

    /// 提交外部事件：已映射事件即时分发为反应（返回是否生效）。
    /// 反应被接受时同帧定格并展示对话气泡（未映射事件无气泡）。
    @discardableResult
    func submit(_ event: PetExternalEvent) -> Bool {
        captureInterruptedRemaining()
        let accepted = engine.submit(event)
        if accepted {
            behaviorState = engine.state
            decisionRemaining = engine.currentReaction?.duration ?? 3
            presentBubble(for: event)
            updateDisplaySnapshot()
        }
        return accepted
    }

    /// 用户点击气泡：仅收起气泡，反应动画继续走完。
    func dismissBubble() {
        guard currentBubble != nil else { return }
        clearBubble()
    }

    /// 定格并展示气泡：文案在反应开始时一次性确定（含变体掷点），期间不变。
    private func presentBubble(for event: PetExternalEvent) {
        guard let kind = event.reactionKind,
              let text = PetBubbleCopy.text(
                for: event,
                strings: strings,
                variantRoll: bubbleVariantRoll()
              ) else { return }
        currentBubble = PetBubbleContent(kind: kind, text: text)
        guard let parent = windowController.panel else { return }
        bubbleController.show(
            text: text,
            parent: parent,
            petFrame: parent.frame,
            screens: visibleScreensProvider(),
            onDismiss: { [weak self] in self?.dismissBubble() }
        )
    }

    private func clearBubble() {
        currentBubble = nil
        bubbleController.hide()
    }

    // MARK: - 菜单动作

    /// 右键菜单「隐藏宠物」：关闭功能开关（窗口随 binding 消失）。
    func requestHide() {
        userDefaults.set(false, forKey: UserDefaultsKeys.petEnabled)
    }

    /// 右键菜单「打开设置」：跳转实用工具页宠物详情。
    func requestOpenSettings() {
        openSettingsHandler?()
    }

    // MARK: - 私有

    /// 自主决策后的状态时长：一次性小动作（玩耍 / 蹦跳）按素材动画总时长取
    /// （播完即转移，不在末帧定格）；其余状态按决策采样时长。
    private func autonomyDuration(for decision: PetBehaviorDecision) -> TimeInterval {
        switch decision.state {
        case .frolic:
            return oneShotDuration(ids: [PetAnimationID.petted], fallback: decision.duration)
        case .hop:
            return oneShotDuration(ids: [PetAnimationID.drag, PetAnimationID.fall], fallback: decision.duration)
        default:
            return decision.duration
        }
    }

    /// 一次性动画态的时长：取首个命中素材的总时长；素材缺失时回退默认值。
    private func oneShotDuration(ids: [String], fallback: TimeInterval) -> TimeInterval {
        for id in ids {
            if let animation = asset?.animation(id: id) {
                return animation.frameDuration * Double(animation.frames.count)
            }
        }
        return fallback
    }

    /// 记录被打断的自主行为剩余时长（仅行走有意义；反应态续期沿用首次记录）。
    private func captureInterruptedRemaining() {
        if case .walk = behaviorState {
            interruptedRemaining = max(decisionRemaining, 0)
        }
    }

    /// 订阅屏幕配置变更（通知在主线程投递，经 Task 落回主actor）。
    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleScreenConfigurationChange()
            }
        }
    }

    private func removeScreenChangeObserver() {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    /// 图集切片缓存失效：同名宠物覆盖更新 / 删除后，旧帧不得残留。
    private func invalidateSpriteCache() {
        SpriteAtlasImageProvider.shared.clearCache()
    }

    /// 重启行为循环（资产切换后应用新尺寸与视图）。
    private func restartIfRunning() {
        guard isRunning else { return }
        teardown()
        start()
    }

    /// 计算窗口尺寸：高度取档位尺寸，宽度按素材宽高比。
    static func petSize(for size: DesktopPetSize, asset: PetSpriteAsset?) -> CGSize {
        let height = size.pointSize
        let ratio = asset?.aspectRatio ?? 1
        return CGSize(width: max(1, (height * ratio).rounded()), height: height)
    }

    /// 解析指定 slug 的资产：自定义优先查宠物库目录，否则回退内置。
    static func resolveAsset(slug: String, store: PetAssetStore) -> PetSpriteAsset? {
        if slug != PetAssetLocator.builtInPetID {
            let directory = store.directory(for: slug)
            let manifest = directory.appendingPathComponent("pet.json")
            if FileManager.default.fileExists(atPath: manifest.path),
               let asset = try? PetAssetLocator.load(from: directory) {
                return asset
            }
        }
        return PetAssetLocator.builtInAsset
    }

    /// 规范化持久化的所选 slug：
    /// - 旧内置 `cat`：库内存在**可加载**的同名自定义资产则保留（用户自装的 cat），
    ///   否则迁移为新内置并回写存储；
    /// - 其他非内置 slug：可加载则保留原值，失效则回退内置并回写（画面与选中态一致）；
    /// - 内置或空值：直接落内置。
    static func normalizedSelectedSlug(stored: String?, store: PetAssetStore) -> String {
        guard let stored, !stored.isEmpty else { return PetAssetLocator.builtInPetID }
        if stored == PetAssetLocator.builtInPetID { return stored }
        // 非内置（含旧 cat）：可加载的自定义资产保留，不可加载一律回内置。
        if customAssetIsLoadable(slug: stored, store: store) {
            return stored
        }
        return PetAssetLocator.builtInPetID
    }

    /// 库内自定义资产是否实际可加载（存在 pet.json 且完整解码）。
    private static func customAssetIsLoadable(slug: String, store: PetAssetStore) -> Bool {
        let directory = store.directory(for: slug)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pet.json").path
        ) else { return false }
        return (try? PetAssetLocator.load(from: directory)) != nil
    }

    /// 恢复上次位置：屏幕标识命中则用之，否则回退默认落点。
    private func restoredOrigin() -> CGPoint? {
        let screens = visibleScreensProvider()
        guard !screens.isEmpty else { return nil }
        let remembered = userDefaults.string(forKey: UserDefaultsKeys.petPositionScreen)
        guard let screen = PetPositionPlanner.resolveScreen(
            rememberedIdentifier: remembered,
            screens: screens,
            mainScreenIdentifier: PetWindowController.mainScreenIdentifier
        ) else { return nil }

        let hasStoredPosition = remembered?.isEmpty == false
        let rawOrigin = CGPoint(
            x: userDefaults.double(forKey: UserDefaultsKeys.petPositionX),
            y: userDefaults.double(forKey: UserDefaultsKeys.petPositionY)
        )
        guard hasStoredPosition else {
            return CGPoint(
                x: screen.visibleFrame.maxX - petSize.width - 40,
                y: screen.groundY
            )
        }
        return PetPositionPlanner.clamp(rawOrigin, petSize: petSize, to: screen)
    }

    private func persistPositionDebounced() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.persistDebounce ?? 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.persistPositionNow()
        }
    }

    private func persistPositionNow() {
        guard let origin = windowController.currentOrigin else { return }
        let screens = visibleScreensProvider()
        let currentPetSize = petSize
        userDefaults.set(Double(origin.x), forKey: UserDefaultsKeys.petPositionX)
        userDefaults.set(Double(origin.y), forKey: UserDefaultsKeys.petPositionY)
        if let screen = PetPositionPlanner.screenContaining(
            position: origin,
            petSize: currentPetSize,
            screens: screens
        ) {
            userDefaults.set(screen.identifier, forKey: UserDefaultsKeys.petPositionScreen)
        }
    }
}
