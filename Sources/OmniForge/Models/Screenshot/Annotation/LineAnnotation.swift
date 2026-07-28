import AppKit
import Foundation

/// 直线标注。参照 capcap `LineAnnotation`：
/// 旋转支持存在但烘焙进端点（rotation 恒为 0），端点 handle 始终落在真实几何上。
struct LineAnnotation: Annotation, Equatable {
    let uuid: UUID
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var lineWidth: CGFloat

    init(uuid: UUID = UUID(), start: CGPoint, end: CGPoint, color: NSColor = .black, lineWidth: CGFloat = 3) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let line = CGMutablePath()
        line.move(to: start)
        line.addLine(to: end)
        return strokedPathContains(point, path: line, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        LineAnnotation(uuid: uuid, start: CGPoint(x: start.x + delta.x, y: start.y + delta.y),
                       end: CGPoint(x: end.x + delta.x, y: end.y + delta.y), color: color, lineWidth: lineWidth)
    }

    var boundingRect: NSRect {
        let margin = max(lineWidth / 2 + strokeHitTolerance, strokeHitTolerance)
        return NSRect(
            x: min(start.x, end.x) - margin,
            y: min(start.y, end.y) - margin,
            width: abs(end.x - start.x) + margin * 2,
            height: abs(end.y - start.y) + margin * 2
        )
    }

    /// 旋转支持：把两端点绕中点旋转 `rotation` 弧度，烘焙进 start/end。
    /// 存储的 rotation 保持 0，端点 handle 始终真实。
    var supportsRotation: Bool { true }
    var rotation: CGFloat { 0 }
    func withRotation(_ rotation: CGFloat) -> Annotation {
        guard rotation != 0 else { return self }
        let center = CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2
        )
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        func rotate(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x
            let dy = p.y - center.y
            return CGPoint(
                x: center.x + dx * cosR - dy * sinR,
                y: center.y + dx * sinR + dy * cosR
            )
        }
        return LineAnnotation(uuid: uuid, start: rotate(start), end: rotate(end), color: color, lineWidth: lineWidth)
    }

    func withColor(_ color: NSColor) -> Annotation { LineAnnotation(uuid: uuid, start: start, end: end, color: color, lineWidth: lineWidth) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { LineAnnotation(uuid: uuid, start: start, end: end, color: color, lineWidth: lineWidth) }

    /// 调整模式：替换起点。
    func withStart(_ p: CGPoint) -> LineAnnotation {
        LineAnnotation(uuid: uuid, start: p, end: end, color: color, lineWidth: lineWidth)
    }

    /// 调整模式：替换终点。
    func withEnd(_ p: CGPoint) -> LineAnnotation {
        LineAnnotation(uuid: uuid, start: start, end: p, color: color, lineWidth: lineWidth)
    }
}
