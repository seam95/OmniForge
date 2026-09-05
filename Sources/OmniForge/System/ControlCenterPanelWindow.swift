import AppKit

// MARK: - 控制中心自管面板窗口

/// 控制中心面板窗口（自管 NSPanel，替代 NSPopover）。
///
/// 迁移动机（docs/active/2026-09-05-控制中心自管窗口/SPEC.md）：NSPopover
/// 会跟随锚点矩形重定位，菜单栏指标数值宽度变化时面板左右移动；NSWindow
/// 无锚定跟随机制，show 时手动定位一次后位置钉死。
///
/// 外壳配方对齐剪贴板面板（ClipboardWindowController）已验证组合：
/// borderless + clear 背景 + 系统阴影 + statusBar 层级；borderless 窗口
/// 默认不可成为 key window，须子类放开。
final class ControlCenterPanelWindow: NSPanel {
    /// 面板内容与屏幕边缘的最小水平内距。
    static let horizontalEdgeInset: CGFloat = 4
    /// 面板顶边与锚点（状态栏按钮）下沿的垂直间隙；同时为系统阴影留出视觉空间。
    static let topGap: CGFloat = 4
    /// 内容圆角半径（对齐 NSPopover 视觉，无箭头）。
    static let cornerRadius: CGFloat = 12

    /// Escape / 失焦等关闭入口由宿主接线（宿主负责会话清理与按钮态复位）。
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        styleMask.insert(.fullSizeContentView)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }

    /// 面板内容的圆角裁剪：hostingView 挂载后由宿主调用。
    /// SwiftUI 容器自带不透明背景，圆角在窗口层裁剪即可获得整体圆角面板。
    func applyContentCornerRadius(_ contentView: NSView) {
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = Self.cornerRadius
        contentView.layer?.masksToBounds = true
    }

    /// Escape 关闭（NSPopover transient 自带行为的自管等价物）。
    /// 文本输入场景下事件可能先被 first responder 消费，宿主另有
    /// local keyDown monitor 兜底。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 定位（纯函数，可测）

    /// 计算面板 frame：水平中心对准锚点中心，贴屏幕可见区左右 clamp；
    /// 顶边 = 锚点下沿 - topGap，向下展开。
    static func panelFrame(
        anchorScreenFrame: CGRect,
        panelSize: NSSize,
        visibleFrame: CGRect
    ) -> NSRect {
        let idealX = anchorScreenFrame.midX - panelSize.width / 2
        let maxX = visibleFrame.maxX - panelSize.width - horizontalEdgeInset
        let minX = visibleFrame.minX + horizontalEdgeInset
        // 面板宽超出可见区（极小屏）时退化为左缘对齐，避免负宽。
        let x = maxX > minX ? min(max(idealX, minX), maxX) : minX
        let topY = anchorScreenFrame.minY - topGap
        // 高度受 availableHeight 约束，正常不低于可见区底；此处仅兜底。
        let y = max(topY - panelSize.height, visibleFrame.minY)
        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
}
