import AppKit

/// 便签正文专用滚动条：overlay 细胶囊 knob、不画轨道槽。
/// 系统 overlay scroller 在纸质浅底上会渲染成突兀的白色长条，
/// 这里自绘 knob（便签文字色半透明）并配合 autohidesScrollers，内容不溢出时完全不显示。
@MainActor
final class StickyNoteScroller: NSScroller {
    /// knob 填充色（由外部按便签色板注入，随深浅色切换更新）。
    var knobColor: NSColor = NSColor.black.withAlphaComponent(0.3) {
        didSet { needsDisplay = true }
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    init() {
        super.init(frame: .zero)
        scrollerStyle = .overlay
        controlSize = .small
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持")
    }

    /// 不画轨道槽，避免纸质底色上出现的浅色长条底。
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let slot = rect(for: .knob)
        guard !slot.isEmpty else { return }
        // 细胶囊：宽 4pt 水平居中，上下各留 2pt 呼吸空隙
        let knobWidth: CGFloat = 4
        let knobRect = NSRect(
            x: slot.midX - knobWidth / 2,
            y: slot.minY + 2,
            width: knobWidth,
            height: max(slot.height - 4, 0)
        )
        let path = NSBezierPath(roundedRect: knobRect, xRadius: knobWidth / 2, yRadius: knobWidth / 2)
        knobColor.setFill()
        path.fill()
    }

    /// 安装到滚动视图并接管竖向滚动条；滚动时淡入、空闲/内容不溢出时自动隐藏。
    @discardableResult
    static func install(on scrollView: NSScrollView) -> StickyNoteScroller {
        let scroller = StickyNoteScroller()
        scrollView.verticalScroller = scroller
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        return scroller
    }
}
