import AppKit
import SwiftUI

/// 承载 SwiftUI 内容的无边框面板托管视图：自带整窗拖动能力。
///
/// 面板不再依赖 `NSWindow.isMovableByWindowBackground`——macOS 27 起该机制对无边框
/// 面板失效（属性链仍报告可拖，但系统不再发起拖动会话）。这里自实现拖动：
/// `mouseDown` 记录起点，`mouseDragged` 位移越过阈值后交给系统原生拖动会话
/// `performDrag(with:)`（与桌宠窗口同一配方，macOS 14+ 行为一致）：
/// - 阈值门控保证单击（SwiftUI 按钮、tab 切换）永不进入拖动会话；
/// - 按下点命中原生控件子视图（搜索框、滚动条等 `mouseDownCanMoveWindow == false`）
///   时不介入，文本选择与滚动条拖动不受影响；
/// - 拖动会话的残余 `mouseUp` 不透传，避免松手补触发一次点击。
final class WindowDragHostingView: NSHostingView<AnyView> {
    /// 进入拖动会话的位移识别阈值（pt）：覆盖触摸板单击的轻微位移（常见 3-5pt）。
    static var dragThreshold: CGFloat { 8 }

    /// 按下时的屏幕坐标（阈值判定用；进入会话后置 nil）。
    private var mouseDownScreenLocation: NSPoint?
    /// 本次按下是否已进入原生拖动会话（决定残余 mouseUp 是否透传）。
    private var didStartDragSession = false
    /// 本次按下是否允许拖动（命中可交互原生控件子视图时为 false）。
    private var isDragArmed = false

    /// 呼出面板后第一次按住即可起拖，不要求窗口先获焦。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let hit = hitTest(convert(event.locationInWindow, from: nil))
        // 命中 hosting view 本体（SwiftUI 空白/按钮/列表行）→ 允许拖动；
        // 命中更深的原生控件子视图 → 按控件声明的可拖性决定（文本框/滚动条为 false），
        // 与旧版系统背景拖动机制的判定口径一致。
        isDragArmed = hit == self || (hit?.mouseDownCanMoveWindow ?? false)
        mouseDownScreenLocation = NSEvent.mouseLocation
        didStartDragSession = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragArmed,
              let start = mouseDownScreenLocation,
              Self.dragExceedsThreshold(from: start, to: NSEvent.mouseLocation) else {
            super.mouseDragged(with: event)
            return
        }
        mouseDownScreenLocation = nil
        didStartDragSession = true
        // 传当前事件：会话锚点 = 光标当前在窗口内的位置，阈值内累计位移不被追溯，
        // 起拖瞬间窗口不跳变。performDrag 为同步调用，松手时返回。
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = didStartDragSession
        didStartDragSession = false
        mouseDownScreenLocation = nil
        isDragArmed = false
        guard !wasDragging else { return }
        super.mouseUp(with: event)
    }

    /// 位移是否越过拖动识别阈值（独立纯函数，便于单测边界语义）。
    static func dragExceedsThreshold(from start: NSPoint, to current: NSPoint) -> Bool {
        let dx = current.x - start.x
        let dy = current.y - start.y
        return (dx * dx + dy * dy).squareRoot() >= dragThreshold
    }
}
