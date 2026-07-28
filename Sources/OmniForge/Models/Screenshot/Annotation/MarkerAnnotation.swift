import AppKit
import Foundation

/// 荧光笔标注（半透明粗笔迹，透明度层防重叠加深）。
/// 绘制参照 capcap `MarkerAnnotation`：笔宽 = lineWidth × brushScale(6)，
/// 在透明度层内全 alpha 绘制后整体拍平为 markerAlpha(0.35)，
/// 这样自重叠段不会在交点处加深。保留 OmniForge 的 `[CGPoint]` API。
struct MarkerAnnotation: Annotation, Equatable {
    let uuid: UUID
    var path: [CGPoint]
    /// 用户选定颜色；alpha 在绘制时统一应用。
    var color: NSColor
    /// 基础宽度，绘制时乘以 brushScale。
    var lineWidth: CGFloat
    var rotation: CGFloat
    let supportsRotation: Bool = true

    static let brushScale: CGFloat = 6
    static let markerAlpha: CGFloat = 0.35

    init(uuid: UUID = UUID(), path: [CGPoint], color: NSColor = .yellow, lineWidth: CGFloat = 12, rotation: CGFloat = 0) {
        self.uuid = uuid
        self.path = path
        self.color = color.withAlphaComponent(1.0) // alpha 在层级别控制
        self.lineWidth = lineWidth
        self.rotation = rotation
    }

    private var bezierPath: NSBezierPath {
        NSBezierPath.smoothed(through: path.map { NSPoint(x: $0.x, y: $0.y) })
    }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let stroke = color.withAlphaComponent(1.0)
        stroke.setStroke()
        let path = bezierPath
        path.lineWidth = lineWidth * Self.brushScale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // 在透明度层内全 alpha 绘制后整体拍平为 markerAlpha，
        // 重叠段不会加深。
        context.setAlpha(Self.markerAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        path.stroke()
        context.endTransparencyLayer()
        context.setAlpha(1.0)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let effectiveWidth = lineWidth * Self.brushScale
        return strokedPathContains(p, path: bezierPath.cgPath, lineWidth: effectiveWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        MarkerAnnotation(uuid: uuid, path: path.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    var boundingRect: NSRect {
        guard !path.isEmpty else { return .zero }
        let inset = -lineWidth * Self.brushScale / 2
        return bezierPath.bounds.insetBy(dx: inset, dy: inset)
    }

    func withRotation(_ rotation: CGFloat) -> Annotation { MarkerAnnotation(uuid: uuid, path: path, color: color, lineWidth: lineWidth, rotation: rotation) }
    func withColor(_ color: NSColor) -> Annotation { MarkerAnnotation(uuid: uuid, path: path, color: color, lineWidth: lineWidth, rotation: rotation) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { MarkerAnnotation(uuid: uuid, path: path, color: color, lineWidth: lineWidth, rotation: rotation) }
}
