import AppKit
import SwiftUI

/// 桌宠对话气泡窗口控制器：宠物主窗的子面板（childWindow 机制自动跟随父窗）。
/// 宠物主窗的位置 / 拖拽 / 多屏逻辑零改动；本控制器只负责展示、载置与点击关闭。
@MainActor
final class PetBubbleWindowController {
    private(set) var panel: NSPanel?
    private let model = PetBubbleViewModel()

    /// 气泡内容最大宽度（点）：短文案单行可容，超长换行两行封顶。
    static let maxContentWidth: CGFloat = 180
    /// 淡出动画时长（秒）；orderOut 延迟须不短于此值。
    private static let fadeOutDuration: TimeInterval = 0.25
    /// 隐藏代际：淡出等待期间再次 show 时作废未完成的 orderOut。
    private var hideGeneration = 0
    /// 点击关闭回调（每次 show 更新；面板复用时视图持有的转发闭包不变）。
    private var onDismissHandler: (() -> Void)?

    /// 展示气泡：量尺定尺寸 → 纯函数载置 → 挂到父窗上方淡入。
    /// - Parameters:
    ///   - text: 定格文案（整个反应期不变；重复调用即同级替换换文案）。
    ///   - parent: 宠物主窗面板。
    ///   - petFrame: 宠物窗口当前帧（AppKit 全局坐标）。
    ///   - screens: 与行为循环同源的屏幕几何。
    ///   - onDismiss: 点击气泡回调（仅关气泡，反应动画继续）。
    func show(
        text: String,
        parent: NSPanel,
        petFrame: CGRect,
        screens: [PetScreenGeometry],
        onDismiss: @escaping () -> Void
    ) {
        hideGeneration += 1
        onDismissHandler = onDismiss
        let panel = ensurePanel()
        if panel.parent !== parent {
            parent.addChildWindow(panel, ordered: .above)
        }

        let size = Self.bubbleSize(for: text)
        model.text = text
        model.size = size
        guard let screen = PetPositionPlanner.screenContaining(
            position: petFrame.origin,
            petSize: petFrame.size,
            screens: screens
        ) ?? screens.first else { return }
        let placement = PetBubblePlacement.resolve(
            petFrame: petFrame,
            bubbleSize: size,
            screen: screen
        )
        model.tailDown = placement.tailDown
        panel.level = parent.level
        panel.setFrame(placement.frame, display: false)
        panel.orderFrontRegardless()
        model.visible = true
    }

    /// 淡出并收起窗口（气泡内容清空；面板保留复用，子窗关系保留）。
    func hide() {
        guard panel != nil else { return }
        hideGeneration += 1
        model.visible = false
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// 销毁面板（宠物 teardown 时随主窗一并关闭）。
    func close() {
        hideGeneration += 1
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel = nil
    }

    // MARK: - 私有

    /// 创建（或复用）气泡面板：透明无边框非激活子面板，系统投影跟随气泡外形。
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = PetHostingView(
            rootView: AnyView(PetSpeechBubbleView(
                model: model,
                onDismiss: { [weak self] in self?.onDismissHandler?() }
            ))
        )
        self.panel = panel
        return panel
    }

    /// 文本量尺：与气泡视图同参数（12pt 系统字、水平 10 / 垂直 7 内边距、最大宽 180、
    /// 尾巴高度另计）用 NSAttributedString 定宽高，避免 SwiftUI fittingSize 的尺寸歧义。
    static func bubbleSize(for text: String) -> CGSize {
        let maxTextWidth = maxContentWidth - 20
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let measured = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = min(max(ceil(measured.width) + 20, 56), maxContentWidth)
        let height = max(ceil(measured.height) + 14, 26) + PetBubbleMetrics.tailHeight
        return CGSize(width: width, height: height)
    }
}
