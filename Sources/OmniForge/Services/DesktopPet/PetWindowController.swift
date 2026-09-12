import AppKit
import SwiftUI

/// 宠物窗口的鼠标事件承载视图。
/// 重写 `acceptsFirstMouse` 让非激活窗口内的第一次点击即响应（不先激活 App、不抢键盘焦点）。
///
/// 拖动由本视图承载（而非 SwiftUI `DragGesture`）：越过阈值后交给系统原生窗口
/// 拖动会话 `performDrag(with:)`，由 WindowServer 批处理移动并与显示刷新对齐。
/// 手动按手势事件率 `setFrame` 的路径会让移动与 30Hz 图层内容提交成为两条无同步的
/// 提交通道，透明面板被合成出中间擦除帧（频闪），且移动间隔不均（抖动）。
/// 单击（未越阈值）永不进入会话，因此不会有会话边界闪帧。
final class PetHostingView<Content: View>: NSHostingView<Content> {
    /// 拖动会话开始 / 结束回调：仅桌宠窗口接线；气泡窗复用本类型但保持 nil，行为不变。
    var onWindowDragStart: (() -> Void)?
    var onWindowDragEnd: (() -> Void)?
    /// 交互锁开始 / 结束：mouseDown（含右键）到对应 mouseUp / 菜单会话结束之间
    /// 窗口必须持续接收事件——alpha 穿透不得在会话中途打开（拖出透明区也不中断拖动）。
    var onInteractionLockStart: (() -> Void)?
    var onInteractionLockEnd: (() -> Void)?

    /// 进入拖动会话的位移识别阈值（pt）。
    static var dragThreshold: CGFloat { 8 }

    /// 按下时的屏幕坐标（判定阈值与是否已启动会话用）。
    private var mouseDownScreenLocation: NSPoint?
    /// 本次按下是否已启动原生拖动会话（松手不再透传给 super，防误触发一次抚摸）。
    private var didStartDragSession = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenLocation = NSEvent.mouseLocation
        didStartDragSession = false
        // 按下即锁：覆盖未达 DragGesture 阈值的按下阶段，帧动画 / 拖出矩形不得中途打开穿透。
        onInteractionLockStart?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // 阈值内不启动会话：触摸板单击的轻微位移（常见 3-5pt）仍按单击处理，
        // 位移透传给 SwiftUI，保持点击手势的既有语义。
        guard let start = mouseDownScreenLocation,
              let begin = onWindowDragStart,
              Self.dragExceedsThreshold(from: start, to: NSEvent.mouseLocation) else {
            super.mouseDragged(with: event)
            return
        }
        mouseDownScreenLocation = nil
        didStartDragSession = true
        begin()
        // 传当前事件：会话锚点 = 当前光标在窗口内的位置，阈值内累计的 ≤8pt 不被追溯，
        // 起拖瞬间不出现位置跳变。performDrag 为同步调用，松手时返回。
        window?.performDrag(with: event)
        // 会话退出跟踪，落点即窗口当前位置。
        onWindowDragEnd?()
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = didStartDragSession
        didStartDragSession = false
        mouseDownScreenLocation = nil
        // 锁随抬起释放（拖动会话的残余抬起同样结束锁）。
        onInteractionLockEnd?()
        // 拖动结束的残余抬起不透传 super，避免 SwiftUI 点击手势补触发一次抚摸。
        guard !wasDragging else { return }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键菜单是模态 tracking 会话：super 返回即菜单已关闭，锁覆盖整个会话。
        onInteractionLockStart?()
        super.rightMouseDown(with: event)
        onInteractionLockEnd?()
    }

    /// 位移是否越过拖动识别阈值（独立纯函数，便于单测边界语义）。
    static func dragExceedsThreshold(from start: NSPoint, to current: NSPoint) -> Bool {
        let dx = current.x - start.x
        let dy = current.y - start.y
        return (dx * dx + dy * dy).squareRoot() >= dragThreshold
    }
}

/// 宠物窗口控制器：透明无边框置顶面板，承载 SwiftUI 宠物视图。
/// 一个控制器对应一只宠物（一宠物一窗口），天然支持二期多宠物。
/// 右键菜单由 SwiftUI 视图层提供，控制器只负责窗口与几何。
@MainActor
final class PetWindowController {
    private(set) var panel: NSPanel?

    /// 拖动会话开始 / 结束回调（由组合根接线，透传给新建的 hosting view）。
    var onWindowDragStart: (() -> Void)?
    var onWindowDragEnd: (() -> Void)?
    /// 交互锁开始 / 结束回调（alpha 穿透的会话期闸门）。
    var onInteractionLockStart: (() -> Void)?
    var onInteractionLockEnd: (() -> Void)?

    /// 当前窗口尺寸（非正方形：按素材宽高比，高度为档位尺寸）。
    private(set) var petSize: CGSize

    /// 最近一次设置的鼠标接收状态（测试断言穿透路由用）。
    private(set) var receivesMouseEvents = true

    init(petSize: CGSize) {
        self.petSize = petSize
    }

    // MARK: - 窗口生命周期

    /// 创建并显示窗口。`initialOrigin` 为窗口左下角坐标（nil 时落到主屏地面右侧）。
    func show(initialOrigin: CGPoint?, rootView: some View) {
        let origin = initialOrigin ?? defaultOrigin(size: petSize)
        let frame = NSRect(origin: origin, size: petSize)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 透明无边框置顶面板：不抢焦点、不激活 App、出现在所有 Space（含全屏）。
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 窗口移动由 PetHostingView 的原生拖动会话接管（越过 8pt 阈值才建会话）：
        // AppKit 背景拖动在单击时也会启动 / 恢复，透明窗口在会话边界处会出现一帧
        // 空白闪烁；阈值门控的 performDrag 让单击永不进会话，该问题已消除。
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hostingView = PetHostingView(rootView: AnyView(rootView))
        hostingView.onWindowDragStart = onWindowDragStart
        hostingView.onWindowDragEnd = onWindowDragEnd
        hostingView.onInteractionLockStart = onInteractionLockStart
        hostingView.onInteractionLockEnd = onInteractionLockEnd
        panel.contentView = hostingView

        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// 关闭窗口并释放视图。
    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    // MARK: - 尺寸与位置

    /// 更新窗口尺寸：保持左下角不动、按新尺寸改窗口大小。
    func apply(petSize newSize: CGSize) {
        guard let panel, newSize != petSize else {
            petSize = newSize
            return
        }
        petSize = newSize
        var frame = panel.frame
        frame.size = newSize
        panel.setFrame(frame, display: true)
        clampToVisibleScreen()
    }

    /// 读取当前窗口位置（左下角）。
    var currentOrigin: CGPoint? {
        panel.map { $0.frame.origin }
    }

    /// 动态设置窗口是否接收鼠标事件（alpha 穿透路由：false = 透明于事件，
    /// 点击到达下层窗口）。值未变化时不重复写窗口属性。
    func setReceivesMouseEvents(_ receives: Bool) {
        guard receives != receivesMouseEvents else { return }
        receivesMouseEvents = receives
        panel?.ignoresMouseEvents = !receives
    }

    /// 移动到指定左下角位置（供行走位移、重置位置、屏幕夹回等程序化路径使用）。
    func move(to origin: CGPoint) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin = origin
        // display: false——行走路径每帧都会调用，透明窗口 display: true 会同步
        // 擦除重绘，高频移动时合成器提交中间擦除帧（宠物频闪）；交给 runloop
        // 周期末尾统一重绘，与显示刷新对齐。拖动不由本方法承担（走原生会话）。
        panel.setFrame(frame, display: false)
    }

    /// 把窗口夹回当前所在屏幕的可见区。
    func clampToVisibleScreen() {
        guard let panel else { return }
        let petSize = panel.frame.size
        let screens = Self.screenGeometries()
        guard let screen = PetPositionPlanner.screenContaining(
            position: panel.frame.origin,
            petSize: petSize,
            screens: screens
        ) else { return }
        let clamped = PetPositionPlanner.clamp(panel.frame.origin, petSize: petSize, to: screen)
        move(to: clamped)
    }

    // MARK: - 屏幕几何

    /// 当前所有屏幕的几何摘要（可见区 + 稳定标识）。
    static func screenGeometries() -> [PetScreenGeometry] {
        NSScreen.screens.map { screen in
            PetScreenGeometry(
                visibleFrame: screen.visibleFrame,
                identifier: identifier(for: screen)
            )
        }
    }

    /// 屏幕稳定标识：优先用系统分配的 displayID，回退到 frame 描述。
    static func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return "frame-\(screen.frame.origin.x)-\(screen.frame.origin.y)"
    }

    /// 主屏标识。
    static var mainScreenIdentifier: String? {
        NSScreen.main.map { identifier(for: $0) }
    }

    /// 默认落点：主屏可见区右下角内侧。
    private func defaultOrigin(size: CGSize) -> CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: frame.maxX - size.width - 40, y: frame.minY)
    }
}
