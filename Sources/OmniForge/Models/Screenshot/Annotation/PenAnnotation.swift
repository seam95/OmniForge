import AppKit
import Foundation

/// 画笔标注（连续自由绘制不透明笔迹，中点二次贝塞尔平滑）。
/// 绘制与命中参照 capcap `PenAnnotation`：用 `NSBezierPath.smoothed(through:)`
/// 构建平滑路径，支持旋转；保留 OmniForge 的 `[CGPoint]` 值类型 API。
struct PenAnnotation: Annotation, Equatable {
    let uuid: UUID
    var path: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var rotation: CGFloat
    let supportsRotation: Bool = true

    init(uuid: UUID = UUID(), path: [CGPoint], color: NSColor = .black, lineWidth: CGFloat = 3, rotation: CGFloat = 0) {
        self.uuid = uuid
        self.path = path
        self.color = color
        self.lineWidth = lineWidth
        self.rotation = rotation
    }

    /// 由原始点序列构建平滑贝塞尔路径。
    private var bezierPath: NSBezierPath {
        NSBezierPath.smoothed(through: path.map { NSPoint(x: $0.x, y: $0.y) })
    }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        color.setStroke()
        let path = bezierPath
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return strokedPathContains(p, path: bezierPath.cgPath, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        PenAnnotation(uuid: uuid, path: path.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    var boundingRect: NSRect {
        guard !path.isEmpty else { return .zero }
        // 包含线宽与命中容差，确保选中 chrome 覆盖可点击区域。
        let margin = max(lineWidth / 2, strokeHitTolerance)
        return bezierPath.bounds.insetBy(dx: -margin, dy: -margin)
    }

    func withRotation(_ rotation: CGFloat) -> Annotation { PenAnnotation(uuid: uuid, path: path, color: color, lineWidth: lineWidth, rotation: rotation) }
    func withColor(_ color: NSColor) -> Annotation { PenAnnotation(uuid: uuid, path: path, color: color, lineWidth: lineWidth, rotation: rotation) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { PenAnnotation(uuid: uuid, path: path, color: color, lineWidth: lineWidth, rotation: rotation) }
}
