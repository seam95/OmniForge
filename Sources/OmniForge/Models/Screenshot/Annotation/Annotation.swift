import AppKit
import Foundation

/// 标注对象协议。
/// 所有标注工具的值类型实现均遵循此协议。
protocol Annotation {
    /// 唯一标识符。
    var uuid: UUID { get }
    /// 在当前 CGContext 中绘制标注。
    func draw(in context: CGContext, bounds: NSRect)

    /// 命中测试：点是否在标注的命中区域内。
    func containsPoint(_ point: NSPoint) -> Bool

    /// 平移后的副本。
    func translated(by delta: NSPoint) -> Annotation

    /// 轴对齐包围盒（用于选中 chrome 和旋转枢轴）。
    var boundingRect: NSRect { get }

    /// 旋转角度（弧度）。
    var rotation: CGFloat { get }

    /// 是否支持旋转。
    var supportsRotation: Bool { get }

    // MARK: - 样式变异器（返回副本）

    func withRotation(_ rotation: CGFloat) -> Annotation
    func withColor(_ color: NSColor) -> Annotation
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation
    func withFontSize(_ fontSize: CGFloat) -> Annotation
    func withFill(_ filled: Bool) -> Annotation
    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation
    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation
}

// MARK: - 协议默认实现

extension Annotation {
    var rotation: CGFloat { 0 }
    var supportsRotation: Bool { false }
    func withRotation(_ rotation: CGFloat) -> Annotation { self }
    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }
    func withFontSize(_ fontSize: CGFloat) -> Annotation { self }
    func withFill(_ filled: Bool) -> Annotation { self }
    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation { self }
    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation { self }

    /// 在旋转变换下绘制。所有 draw 方法按未旋转坐标编写，
    /// 本方法是旋转的唯一应用点。
    func drawApplyingTransforms(in context: CGContext, bounds: NSRect) {
        guard rotation != 0, supportsRotation else {
            draw(in: context, bounds: bounds)
            return
        }
        let center = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: rotation)
        context.translateBy(x: -center.x, y: -center.y)
        draw(in: context, bounds: bounds)
        context.restoreGState()
    }

    /// 将画布坐标点反旋转到标注的未旋转坐标系。
    func unrotate(_ point: NSPoint) -> NSPoint {
        guard rotation != 0, supportsRotation else { return point }
        let c = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
        let dx = point.x - c.x
        let dy = point.y - c.y
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        return NSPoint(
            x: c.x + dx * cosR - dy * sinR,
            y: c.y + dx * sinR + dy * cosR
        )
    }
}
