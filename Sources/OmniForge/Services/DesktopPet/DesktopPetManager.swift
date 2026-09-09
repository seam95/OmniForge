import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// 桌面宠物领域服务：窗口、行为循环、位置 / 尺寸 / 穿透持久化。
/// 重接线 feature：install 时按 `petEnabled` 建窗并恢复状态，teardown 时窗口消失 + 循环停止。
@MainActor
final class DesktopPetManager: ObservableObject {
    /// 当前宠物状态（供视图渲染帧动画）。
    @Published private(set) var behaviorState: PetBehaviorState = .idle
    /// 当前尺寸档位。
    @Published private(set) var size: DesktopPetSize
    /// 是否点击穿透。
    @Published private(set) var isClickThrough: Bool

    /// 行为循环 tick 间隔（秒）；测试注入更长间隔避免时序抖动。
    private let tickInterval: TimeInterval
    /// 位置持久化防抖间隔。
    private let persistDebounce: TimeInterval

    private let userDefaults: UserDefaults
    /// 窗口控制器（测试断言窗口生命周期与位置用；外部不应直接改窗口状态）。
    let windowController: PetWindowController
    private let engine: PetBehaviorEngine
    private let asset: PetSpriteAsset?
    private let visibleScreensProvider: () -> [PetScreenGeometry]
    private let stringsProvider: () -> Strings
    /// 打开设置页回调（组合根接线）。
    var openSettingsHandler: (() -> Void)?

    private var tickTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var decisionRemaining: TimeInterval = 0
    /// 窗口拖动监听：拖拽中不跑行为循环，松手后按落地状态恢复。
    private var isDragging = false
    /// 行走活动锚点（宠物左下角 x）：拖拽松手 / 重置位置时更新，
    /// 宠物只在锚点左右 `walkRadius` 范围内活动，不会满屏乱走。
    private var walkAnchorX: CGFloat?

    /// 行走活动半径（点）：以锚点为中心的水平活动半宽。
    private let walkRadius: CGFloat = 120

    init(
        userDefaults: UserDefaults = .standard,
        windowController: PetWindowController? = nil,
        engine: PetBehaviorEngine? = nil,
        asset: PetSpriteAsset? = nil,
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s },
        visibleScreensProvider: (() -> [PetScreenGeometry])? = nil,
        tickInterval: TimeInterval = 1.0 / 30.0,
        persistDebounce: TimeInterval = 0.5
    ) {
        self.userDefaults = userDefaults
        self.stringsProvider = stringsProvider
        self.visibleScreensProvider = visibleScreensProvider ?? { PetWindowController.screenGeometries() }
        self.engine = engine ?? PetBehaviorEngine()
        self.asset = asset
        self.tickInterval = tickInterval
        self.persistDebounce = persistDebounce
        let resolvedSize = DesktopPetSize.from(userDefaults.integer(forKey: UserDefaultsKeys.petSize))
        self.size = resolvedSize
        self.isClickThrough = userDefaults.bool(forKey: UserDefaultsKeys.petClickThrough)
        self.windowController = windowController ?? PetWindowController(size: resolvedSize)
    }

    // MARK: - 生命周期

    /// 功能启用：建窗、恢复位置与偏好、启动行为循环。
    func start() {
        guard tickTask == nil else { return }
        behaviorState = .idle
        engine.resetToIdle()
        engine.drainExternalEvents()
        let origin = restoredOrigin()
        // 恢复位置即初始活动锚点，重启后不会跑到别处。
        walkAnchorX = origin?.x
        windowController.show(
            initialOrigin: origin,
            rootView: PetSpriteView(manager: self, asset: asset)
        )
        windowController.setClickThrough(isClickThrough)
        startTicking()
    }

    /// 功能停用 / 卸载 / App 退出：窗口立即消失并停止所有定时器。
    func teardown() {
        tickTask?.cancel()
        tickTask = nil
        persistTask?.cancel()
        persistTask = nil
        decisionRemaining = 0
        isDragging = false
        walkAnchorX = nil
        behaviorState = .idle
        engine.drainExternalEvents()
        windowController.close()
    }

    // MARK: - 偏好

    /// 当前语言字符串（视图层取文案用）。
    var strings: Strings { stringsProvider() }

    /// 切换尺寸档位并持久化。
    func setSize(_ newSize: DesktopPetSize) {
        guard newSize != size else { return }
        size = newSize
        userDefaults.set(newSize.rawValue, forKey: UserDefaultsKeys.petSize)
        windowController.apply(size: newSize)
    }

    /// 切换点击穿透并持久化。
    func setClickThrough(_ enabled: Bool) {
        guard enabled != isClickThrough else { return }
        isClickThrough = enabled
        userDefaults.set(enabled, forKey: UserDefaultsKeys.petClickThrough)
        windowController.setClickThrough(enabled)
    }

    /// 重置到所在屏默认位置（右侧地面）。
    func resetPosition() {
        let screens = visibleScreensProvider()
        guard let screen = PetPositionPlanner.screenContaining(
            position: windowController.currentOrigin ?? .zero,
            petSize: CGSize(width: size.pointSize, height: size.pointSize),
            screens: screens
        ) ?? screens.first else { return }
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.pointSize - 40,
            y: screen.groundY
        )
        windowController.move(to: origin)
        walkAnchorX = origin.x
        persistPositionDebounced()
        engine.resetToIdle()
        behaviorState = .idle
    }

    // MARK: - 行为循环

    private func startTicking() {
        tickTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.tickInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 单次行为推进：按当前状态驱动位移、重力与状态转移。
    func tick() {
        // 窗口已消失（teardown 后）时自愈停表，避免残留任务空转。
        guard windowController.panel != nil else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard !isDragging else { return }
        let dt = tickInterval
        let petSize = CGSize(width: size.pointSize, height: size.pointSize)
        let screens = visibleScreensProvider()
        guard let origin = windowController.currentOrigin,
              let screen = PetPositionPlanner.screenContaining(
                position: origin,
                petSize: petSize,
                screens: screens
              ) ?? screens.first else { return }

        switch behaviorState {
        case .idle:
            decisionRemaining -= dt
            if decisionRemaining <= 0 {
                let decision = engine.nextIdleDecision()
                engine.apply(decision)
                decisionRemaining = decision.duration
                behaviorState = decision.state
            }

        case .walk(let direction):
            decisionRemaining -= dt
            // walkDelta 已含方向符号，位置规划需要正数步长。
            let anchorX = walkAnchorX ?? origin.x
            let range = PetPositionPlanner.walkRange(
                anchorX: anchorX,
                radius: walkRadius,
                petSize: petSize,
                screen: screen
            )
            let step = PetPositionPlanner.stepWalk(
                position: origin,
                direction: direction,
                distance: abs(engine.walkDelta(dt: dt)),
                walkRange: range
            )
            windowController.move(to: step.position)
            persistPositionDebounced()
            // 边缘转身后方向改变，需同步状态。
            if step.direction != direction {
                engine.apply(PetBehaviorDecision(
                    state: .walk(direction: step.direction),
                    horizontalDelta: 0,
                    duration: max(decisionRemaining, 0.5)
                ))
                behaviorState = .walk(direction: step.direction)
            } else if decisionRemaining <= 0 {
                engine.apply(PetBehaviorDecision(state: .idle, horizontalDelta: 0, duration: 0))
                behaviorState = .idle
            }

        case .drag:
            // 拖拽期间位置由 AppKit 窗口拖动接管，循环只等状态变化。
            break

        case .petted:
            decisionRemaining -= dt
            if decisionRemaining <= 0 {
                engine.finishPetted()
                behaviorState = engine.state
                decisionRemaining = 0
            }
        }
    }

    // MARK: - 交互

    /// 单击抚摸。
    func pet() {
        engine.pet()
        guard case .petted = engine.state else { return }
        behaviorState = engine.state
        // 抚摸动画时长由资产定义，缺资产时给一个保守值。
        decisionRemaining = asset?.animation(id: PetAnimationID.petted)
            .map { $0.frameDuration * Double($0.frames.count) } ?? 0.6
    }

    /// 拖拽开始。
    func beginDrag() {
        isDragging = true
        engine.beginDrag()
        behaviorState = .drag
    }

    /// 拖拽结束：宠物悬停在松手处并回到 idle，该处成为新的行走活动锚点。
    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        // 以松手处为活动锚点：之后只在附近走动，不再满屏游走。
        walkAnchorX = windowController.currentOrigin?.x
        engine.endDrag()
        behaviorState = engine.state
        decisionRemaining = 0
        persistPositionDebounced()
    }

    /// 显示器配置变更：夹回可见区并回到 idle。
    func handleScreenConfigurationChange() {
        guard windowController.panel != nil else { return }
        windowController.clampToVisibleScreen()
        engine.resetToIdle()
        behaviorState = .idle
        decisionRemaining = 0
        persistPositionDebounced()
    }

    // MARK: - 二期事件入口（形状锁定）

    /// 提交外部事件。一期只入队，不影响行为。
    func submit(_ event: PetExternalEvent) {
        engine.submit(event)
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
        let petSize = CGSize(width: size.pointSize, height: size.pointSize)
        guard hasStoredPosition else {
            return CGPoint(
                x: screen.visibleFrame.maxX - size.pointSize - 40,
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
        let petSize = CGSize(width: size.pointSize, height: size.pointSize)
        userDefaults.set(Double(origin.x), forKey: UserDefaultsKeys.petPositionX)
        userDefaults.set(Double(origin.y), forKey: UserDefaultsKeys.petPositionY)
        if let screen = PetPositionPlanner.screenContaining(
            position: origin,
            petSize: petSize,
            screens: screens
        ) {
            userDefaults.set(screen.identifier, forKey: UserDefaultsKeys.petPositionScreen)
        }
    }
}
