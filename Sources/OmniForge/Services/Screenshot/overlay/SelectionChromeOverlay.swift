import AppKit

/// 画在编辑器 canvas 之上的选区 chrome：虚线边框 + 8 控制点 + 尺寸标签。
/// 仅 handle 命中时 claim 事件，驱动 `SelectionView` 的 external resize API；
/// 其余区域透传给下方 canvas / SelectionView。
final class SelectionChromeOverlay: NSView {
    weak var selectionView: SelectionView?

    private(set) var selectionRectInView: NSRect = .zero
    private(set) var isActiveAndVisible: Bool = false

    private let accentColor = NSColor(red: 0, green: 212.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)
    private let handleSize: CGFloat = 8
    private let handleHitSize: CGFloat = 12
    private let borderWidth: CGFloat = 2.0
    private let dashPattern: [CGFloat] = [6, 4]

    private var dragHandle: SelectionView.HandlePosition?
    private var dragOriginalRect: NSRect = .zero

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(rect: NSRect, active: Bool) {
        let changed = (rect != selectionRectInView) || (active != isActiveAndVisible)
        selectionRectInView = rect
        isActiveAndVisible = active
        if changed {
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActiveAndVisible else { return nil }
        // `point` 在 superview 坐标系。
        let local = convert(point, from: superview)
        guard SelectionView.hitTestHandle(
            point: local,
            rect: selectionRectInView,
            hitSize: handleHitSize
        ) != nil else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = SelectionView.hitTestHandle(
            point: point,
            rect: selectionRectInView,
            hitSize: handleHitSize
        ) else { return }
        dragHandle = handle
        dragOriginalRect = selectionRectInView
        SelectionView.setCursorForHandle(handle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = dragHandle, let selectionView else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionView.resizeByExternalDrag(
            handle: handle,
            originalRect: dragOriginalRect,
            currentPoint: point
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragHandle = nil }
        guard dragHandle != nil, let selectionView else { return }
        selectionView.finalizeExternalResize()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActiveAndVisible else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = SelectionView.hitTestHandle(
            point: point,
            rect: selectionRectInView,
            hitSize: handleHitSize
        ) {
            SelectionView.setCursorForHandle(handle)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActiveAndVisible,
              selectionRectInView.width > 0,
              selectionRectInView.height > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let rect = selectionRectInView
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(accentColor.cgColor)
        context.setLineWidth(borderWidth)
        context.setLineDash(phase: 0, lengths: dashPattern)
        context.stroke(rect.insetBy(dx: -1, dy: -1))
        context.setLineDash(phase: 0, lengths: [])

        let halfHandle = handleSize / 2
        for (_, center) in SelectionView.handlePositions(for: rect) {
            let handleRect = NSRect(
                x: center.x - halfHandle,
                y: center.y - halfHandle,
                width: handleSize,
                height: handleSize
            )
            context.setFillColor(accentColor.cgColor)
            context.fillEllipse(in: handleRect)
        }

        // SelectionView 底层也会画尺寸标签，但 canvas/beautify 可能盖住；在此重绘。
        drawSizeLabel(rect: rect, in: context)
    }

    private func drawSizeLabel(rect: NSRect, in ctx: CGContext) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let labelRect = CGRect(
            x: rect.origin.x,
            y: rect.maxY + 4,
            width: size.width + 8,
            height: size.height + 4
        )
        let bgPath = CGPath(roundedRect: labelRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        let textPoint = CGPoint(x: labelRect.origin.x + 4, y: labelRect.origin.y + 2)
        (label as NSString).draw(at: textPoint, withAttributes: attributes)
    }
}
