import AppKit
import Foundation

/// 编号徽章标注。参照 capcap `NumberAnnotation`：
/// 带编号圆徽，可选拉出箭头（直线或二次贝塞尔曲线），编号文字自动黑白对比。
struct NumberAnnotation: Annotation, Equatable {
    let uuid: UUID
    var center: CGPoint
    /// 拉出箭头尖端（nil 或在徽章内为无箭头）。
    var tip: CGPoint?
    /// 可选曲线控制点（与 tip 同时设置时箭杆为二次贝塞尔）。
    var controlPoint: CGPoint?
    var number: Int
    var color: NSColor

    static let radius: CGFloat = 14
    /// tip 距 center 小于此值视为无箭头，避免箭头压在徽章上。
    static let arrowMinDistance: CGFloat = NumberAnnotation.radius + 6

    let supportsRotation: Bool = false
    var rotation: CGFloat { 0 }

    init(uuid: UUID = UUID(), center: CGPoint, number: Int, color: NSColor = .red, tip: CGPoint? = nil, controlPoint: CGPoint? = nil) {
        self.uuid = uuid
        self.center = center
        self.number = number
        self.color = color
        self.tip = tip
        self.controlPoint = controlPoint
    }

    /// 黑色徽章配白字，白色徽章配黑字——按感知亮度阈值。参照 capcap。
    static func contrastingTextColor(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    var hasArrow: Bool {
        guard let tip else { return false }
        return hypot(tip.x - center.x, tip.y - center.y) >= NumberAnnotation.arrowMinDistance
    }

    var circleRect: NSRect {
        NSRect(
            x: center.x - NumberAnnotation.radius,
            y: center.y - NumberAnnotation.radius,
            width: NumberAnnotation.radius * 2,
            height: NumberAnnotation.radius * 2
        )
    }

    var boundingRect: NSRect {
        guard hasArrow, let tip else { return circleRect }
        var rect = circleRect.union(NSRect(x: tip.x, y: tip.y, width: 0, height: 0))
        if let cp = controlPoint {
            rect = rect.union(NSRect(x: cp.x, y: cp.y, width: 0, height: 0))
        }
        return rect
    }

    /// 曲线 handle 默认位置：center 到 tip 的中点（仅有箭头时）。
    var defaultCurveMid: CGPoint? {
        guard hasArrow, let tip else { return nil }
        return CGPoint(x: (center.x + tip.x) / 2, y: (center.y + tip.y) / 2)
    }

    /// 曲线 handle 渲染位置：controlPoint 或几何中点，nil 表示无箭头。
    var curveHandlePoint: CGPoint? {
        controlPoint ?? defaultCurveMid
    }

    func draw(in context: CGContext, bounds: NSRect) {
        // 先画箭杆 + 头，徽章压在上面隐藏圆内的箭杆段。
        if hasArrow, let tip {
            let shaftWidth = NumberArrowShape.shaftWidth
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(shaftWidth)
            context.setLineCap(.round)

            // tip 处切线方向决定箭头朝向。
            let endTangent: (dx: CGFloat, dy: CGFloat)
            if let cp = controlPoint {
                endTangent = (tip.x - cp.x, tip.y - cp.y)
            } else {
                endTangent = (tip.x - center.x, tip.y - center.y)
            }

            let tlen = hypot(endTangent.dx, endTangent.dy)
            if tlen > 0 {
                let unitX = endTangent.dx / tlen
                let unitY = endTangent.dy / tlen
                let headLength = NumberArrowShape.headLength
                let baseX = tip.x - unitX * headLength
                let baseY = tip.y - unitY * headLength

                // 箭杆止于箭头底，圆头线帽藏在三角内。
                if let cp = controlPoint {
                    let t = max(0, min(1, 1 - headLength / (2 * tlen)))
                    let a = CGPoint(x: center.x + (cp.x - center.x) * t, y: center.y + (cp.y - center.y) * t)
                    let b = CGPoint(x: cp.x + (tip.x - cp.x) * t, y: cp.y + (tip.y - cp.y) * t)
                    let shaftEnd = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    context.move(to: center)
                    context.addQuadCurve(to: shaftEnd, control: a)
                    context.strokePath()
                } else {
                    context.move(to: center)
                    context.addLine(to: CGPoint(x: baseX, y: baseY))
                    context.strokePath()
                }

                NumberArrowShape.drawHead(tip: tip, unitX: unitX, unitY: unitY, in: context)
            }
        }

        // 实心圆徽。
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circleRect)

        // 编号文字（永远正立），按徽章色选对比文字色。
        let text = "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NumberAnnotation.contrastingTextColor(for: color),
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textOrigin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        (text as NSString).draw(at: textOrigin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        // 徽章命中。
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = NumberAnnotation.radius
        if dx * dx + dy * dy <= r * r {
            return true
        }
        // 箭杆命中（仅有箭头时）。
        if hasArrow, let tip {
            let line = CGMutablePath()
            line.move(to: center)
            if let cp = controlPoint {
                line.addQuadCurve(to: tip, control: cp)
            } else {
                line.addLine(to: tip)
            }
            return strokedPathContains(point, path: line, lineWidth: 4)
        }
        return false
    }

    func translated(by delta: NSPoint) -> Annotation {
        NumberAnnotation(
            uuid: uuid,
            center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
            number: number,
            color: color,
            tip: tip.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            controlPoint: controlPoint.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        )
    }

    func withColor(_ color: NSColor) -> Annotation { NumberAnnotation(uuid: uuid, center: center, number: number, color: color, tip: tip, controlPoint: controlPoint) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }

    /// 调整模式：替换（或清除）箭头尖端。清空 tip 同时清掉 controlPoint。
    func withTip(_ tip: CGPoint?) -> NumberAnnotation {
        var copy = self
        copy.tip = tip
        if tip == nil { copy.controlPoint = nil }
        return copy
    }

    /// 调整模式：替换（或清除）曲线控制点。
    func withControlPoint(_ cp: CGPoint?) -> NumberAnnotation {
        var copy = self
        copy.controlPoint = cp
        return copy
    }

    /// 调整模式：替换编号（由选中 chrome 的 +/- 步进器驱动）。
    func withNumber(_ number: Int) -> NumberAnnotation {
        NumberAnnotation(uuid: uuid, center: center, number: number, color: color, tip: tip, controlPoint: controlPoint)
    }
}

/// 放大镜标注。参照 capcap `MagnifierAnnotation`：
/// 以 sourceCenter 为中心采样 `2·radius/zoom` 宽区域，放大 zoom 倍填满镜头圆；
/// sourceCenter 可拖出（detached）形成源点指示器 + 连接线。
struct MagnifierAnnotation: Annotation, Equatable {
    let uuid: UUID
    var center: CGPoint
    var radius: CGFloat
    var color: NSColor
    var lineWidth: CGFloat
    /// 放大倍数：镜头显示 `2·radius/zoom` 宽的区域。
    var zoom: CGFloat
    /// 被放大的底图，每次 draw 重新采样。
    var sourceImage: NSImage
    /// 可选采样中心点；nil 表示经典 loupe 行为（采样镜头正下方）。
    var sourceCenter: CGPoint?

    static let defaultZoom: CGFloat = 2.0
    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 6.0
    static let zoomStep: CGFloat = 0.5
    /// 镜头最小半径。
    static let minRadius: CGFloat = 16
    /// 源点 handle 拖到距镜头中心此距离内时重置为"放大正下方"。
    static let sourceResetDistance: CGFloat = 8

    let supportsRotation: Bool = false
    var rotation: CGFloat { 0 }

    var effectiveSourceCenter: CGPoint {
        sourceCenter ?? center
    }

    var boundingRect: NSRect {
        NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    init(uuid: UUID = UUID(), center: CGPoint, radius: CGFloat, color: NSColor, lineWidth: CGFloat, zoom: CGFloat, sourceImage: NSImage, sourceCenter: CGPoint? = nil) {
        self.uuid = uuid
        self.center = center
        self.radius = radius
        self.color = color
        self.lineWidth = lineWidth
        self.zoom = zoom
        self.sourceImage = sourceImage
        self.sourceCenter = sourceCenter
    }

    private static func sourceIndicatorRadius(for lensRadius: CGFloat) -> CGFloat {
        max(12, min(24, lensRadius * 0.14))
    }

    /// detached 源点的几何（源点指示器 + 连接线起止）。nil 表示无 detached 源点。
    private var detachedSourceGeometry: (source: CGPoint, start: CGPoint, end: CGPoint, indicatorRadius: CGFloat)? {
        guard let source = sourceCenter else { return nil }
        let dx = source.x - center.x
        let dy = source.y - center.y
        let distance = hypot(dx, dy)
        let indicatorRadius = Self.sourceIndicatorRadius(for: radius)
        guard distance > radius + indicatorRadius + 2 else { return nil }

        let ux = dx / distance
        let uy = dy / distance
        return (
            source: source,
            start: CGPoint(x: center.x + ux * radius, y: center.y + uy * radius),
            end: CGPoint(x: source.x - ux * indicatorRadius, y: source.y - uy * indicatorRadius),
            indicatorRadius: indicatorRadius
        )
    }

    func draw(in context: CGContext, bounds: NSRect) {
        guard radius > 6, let nsContext = NSGraphicsContext.current else { return }

        let squareRect = boundingRect
        let circle = NSBezierPath(ovalIn: squareRect)

        if let geometry = detachedSourceGeometry {
            drawSourceConnector(geometry, in: context)
        }

        // 放大内容裁剪到圆。采样区域为 `2·radius/zoom` 宽（canvas 坐标），
        // 以 effectiveSourceCenter 为中心，映射到图像坐标系后放大填满 lensRect。
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let imgSize = sourceImage.size
        let scaleX = bounds.width > 0 ? imgSize.width / bounds.width : 1
        let scaleY = bounds.height > 0 ? imgSize.height / bounds.height : 1
        let srcSize = (radius * 2) / max(zoom, 1)
        let sampleCenter = effectiveSourceCenter
        let fromRect = NSRect(
            x: (sampleCenter.x - srcSize / 2) * scaleX,
            y: (sampleCenter.y - srcSize / 2) * scaleY,
            width: srcSize * scaleX,
            height: srcSize * scaleY
        )
        nsContext.imageInterpolation = .high
        sourceImage.draw(in: squareRect, from: fromRect, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // 镜片描边。
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: squareRect)

        if let geometry = detachedSourceGeometry {
            drawSourceIndicator(geometry, in: context)
        }
    }

    private func drawSourceConnector(
        _ geometry: (source: CGPoint, start: CGPoint, end: CGPoint, indicatorRadius: CGFloat),
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        context.move(to: geometry.start)
        context.addLine(to: geometry.end)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSourceIndicator(
        _ geometry: (source: CGPoint, start: CGPoint, end: CGPoint, indicatorRadius: CGFloat),
        in context: CGContext
    ) {
        let rect = NSRect(
            x: geometry.source.x - geometry.indicatorRadius,
            y: geometry.source.y - geometry.indicatorRadius,
            width: geometry.indicatorRadius * 2,
            height: geometry.indicatorRadius * 2
        )
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        if hypot(point.x - center.x, point.y - center.y) <= radius {
            return true
        }
        guard let geometry = detachedSourceGeometry else { return false }
        if hypot(point.x - geometry.source.x, point.y - geometry.source.y) <= geometry.indicatorRadius + 5 {
            return true
        }
        return distanceFromPoint(point, toSegment: geometry.start, end: geometry.end) <= 6
    }

    func translated(by delta: NSPoint) -> Annotation {
        MagnifierAnnotation(
            uuid: uuid,
            center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: sourceCenter
        )
    }

    /// 平移镜头但保持源点焦点（拖动镜头体时）。
    func translatedPreservingSourceFocus(by delta: NSPoint) -> MagnifierAnnotation {
        MagnifierAnnotation(
            uuid: uuid,
            center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
            radius: radius,
            color: color,
            lineWidth: lineWidth,
            zoom: zoom,
            sourceImage: sourceImage,
            sourceCenter: effectiveSourceCenter
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        MagnifierAnnotation(uuid: uuid, center: center, radius: radius, color: color, lineWidth: lineWidth, zoom: zoom, sourceImage: sourceImage, sourceCenter: sourceCenter)
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        MagnifierAnnotation(uuid: uuid, center: center, radius: radius, color: color, lineWidth: lineWidth, zoom: zoom, sourceImage: sourceImage, sourceCenter: sourceCenter)
    }

    /// 调整模式：替换半径。
    func withRadius(_ radius: CGFloat) -> MagnifierAnnotation {
        MagnifierAnnotation(uuid: uuid, center: center, radius: radius, color: color, lineWidth: lineWidth, zoom: zoom, sourceImage: sourceImage, sourceCenter: sourceCenter)
    }

    /// 调整模式：替换（或清除）源点中心。
    func withSourceCenter(_ sourceCenter: CGPoint?) -> MagnifierAnnotation {
        MagnifierAnnotation(uuid: uuid, center: center, radius: radius, color: color, lineWidth: lineWidth, zoom: zoom, sourceImage: sourceImage, sourceCenter: sourceCenter)
    }

    /// 调整模式：替换放大倍数（夹取到 minZoom...maxZoom）。
    func withZoom(_ zoom: CGFloat) -> MagnifierAnnotation {
        MagnifierAnnotation(uuid: uuid, center: center, radius: radius, color: color, lineWidth: lineWidth, zoom: min(max(zoom, Self.minZoom), Self.maxZoom), sourceImage: sourceImage, sourceCenter: sourceCenter)
    }
}
