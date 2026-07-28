import AppKit
import Foundation

/// 矩形标注。绘制与命中逻辑参照 capcap `RectAnnotation`：
/// 支持 standard/rounded/handDrawn 三种描边样式与 none/opaque/translucent 填充。
struct RectAnnotation: Annotation, Equatable {
    let uuid: UUID
    var rect: NSRect
    var color: NSColor
    var lineWidth: CGFloat
    var fillMode: ShapeFillMode
    var strokeStyle: ShapeStrokeStyle
    var roughStyle: RoughShapeStyle
    var rotation: CGFloat
    let supportsRotation: Bool = true

    init(uuid: UUID = UUID(), rect: NSRect, color: NSColor = .red, lineWidth: CGFloat = 2,
         fillMode: ShapeFillMode = .none, strokeStyle: ShapeStrokeStyle = .standard,
         roughStyle: RoughShapeStyle? = nil, rotation: CGFloat = 0) {
        self.uuid = uuid
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.fillMode = fillMode
        self.strokeStyle = strokeStyle
        self.roughStyle = roughStyle ?? RoughShapeStyle.make(rect: rect, lineWidth: lineWidth)
        self.rotation = rotation
    }

    var filled: Bool { fillMode.isFilled }

    func draw(in context: CGContext, bounds: NSRect) {
        ShapeDrawing.fillRect(rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
        ShapeDrawing.strokeRect(rect, color: color, lineWidth: lineWidth, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = ShapeDrawing.rectPath(rect, lineWidth: lineWidth, strokeStyle: strokeStyle)
        if filled, path.contains(p) {
            return true
        }
        return strokedPathContains(p, path: path, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        RectAnnotation(uuid: uuid, rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    var boundingRect: NSRect { rect }

    func withRotation(_ rotation: CGFloat) -> Annotation { RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withColor(_ color: NSColor) -> Annotation { RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle.tuned(for: rect, lineWidth: lineWidth), rotation: rotation) }
    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation { RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation { RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withFill(_ filled: Bool) -> Annotation { RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: filled ? .opaque : .none, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }

    /// 调整模式：替换矩形。
    func withRect(_ rect: NSRect) -> RectAnnotation {
        RectAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle.tuned(for: rect, lineWidth: lineWidth), rotation: rotation)
    }
}

/// 椭圆标注。绘制与命中逻辑参照 capcap `EllipseAnnotation`。
struct EllipseAnnotation: Annotation, Equatable {
    let uuid: UUID
    var rect: NSRect
    var color: NSColor
    var lineWidth: CGFloat
    var fillMode: ShapeFillMode
    var strokeStyle: ShapeStrokeStyle
    var roughStyle: RoughShapeStyle
    var rotation: CGFloat
    let supportsRotation: Bool = true

    init(uuid: UUID = UUID(), rect: NSRect, color: NSColor = .red, lineWidth: CGFloat = 2,
         fillMode: ShapeFillMode = .none, strokeStyle: ShapeStrokeStyle = .standard,
         roughStyle: RoughShapeStyle? = nil, rotation: CGFloat = 0) {
        self.uuid = uuid
        self.rect = rect
        self.color = color
        self.lineWidth = lineWidth
        self.fillMode = fillMode
        self.strokeStyle = strokeStyle
        self.roughStyle = roughStyle ?? RoughShapeStyle.make(rect: rect, lineWidth: lineWidth)
        self.rotation = rotation
    }

    var filled: Bool { fillMode.isFilled }

    func draw(in context: CGContext, bounds: NSRect) {
        ShapeDrawing.fillEllipse(rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
        ShapeDrawing.strokeEllipse(rect, color: color, lineWidth: lineWidth, strokeStyle: strokeStyle, roughStyle: roughStyle, in: context)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = CGPath(ellipseIn: rect, transform: nil)
        if filled, path.contains(p) {
            return true
        }
        return strokedPathContains(p, path: path, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EllipseAnnotation(uuid: uuid, rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation)
    }

    var boundingRect: NSRect { rect }

    func withRotation(_ rotation: CGFloat) -> Annotation { EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withColor(_ color: NSColor) -> Annotation { EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle.tuned(for: rect, lineWidth: lineWidth), rotation: rotation) }
    func withShapeFillMode(_ fillMode: ShapeFillMode) -> Annotation { EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withShapeStrokeStyle(_ strokeStyle: ShapeStrokeStyle) -> Annotation { EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }
    func withFill(_ filled: Bool) -> Annotation { EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: filled ? .opaque : .none, strokeStyle: strokeStyle, roughStyle: roughStyle, rotation: rotation) }

    /// 调整模式：替换椭圆外接矩形。
    func withRect(_ rect: NSRect) -> EllipseAnnotation {
        EllipseAnnotation(uuid: uuid, rect: rect, color: color, lineWidth: lineWidth, fillMode: fillMode, strokeStyle: strokeStyle, roughStyle: roughStyle.tuned(for: rect, lineWidth: lineWidth), rotation: rotation)
    }
}
