import AppKit
import CoreGraphics
import Foundation

/// 箭头标注（四样式 + 可弯曲）。
///
/// 几何与绘制逻辑完全参照 capcap 的 `ArrowAnnotation`
/// （`Editor/Annotations.swift` L1310-1943）：四样式共用 `arrowGeometry`
/// （tapered）/ `strokedGeometry` + `strokedMetrics`（其余三样式），
/// 短箭头按 spanLength 比例缩放，描边箭杆两端按头长内缩，
/// 曲线箭头用双偏移二次贝塞尔带近似偏移。
struct ArrowAnnotation: Annotation, Equatable {
    let uuid: UUID

    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var lineWidth: CGFloat
    var style: ArrowStyle
    /// 曲线控制点（nil 时箭头为直线）。设置后箭杆按二次贝塞尔绘制，
    /// 箭头朝向沿曲线终点切线。
    var controlPoint: CGPoint?

    init(uuid: UUID = UUID(), start: CGPoint, end: CGPoint, color: NSColor = .red, lineWidth: CGFloat = 2,
         style: ArrowStyle = .tapered, controlPoint: CGPoint? = nil) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
        self.style = style
        self.controlPoint = controlPoint
    }

    // MARK: - 包围盒

    var boundingRect: NSRect {
        var minX = min(start.x, end.x)
        var minY = min(start.y, end.y)
        var maxX = max(start.x, end.x)
        var maxY = max(start.y, end.y)
        if let cp = controlPoint {
            minX = min(minX, cp.x); maxX = max(maxX, cp.x)
            minY = min(minY, cp.y); maxY = max(maxY, cp.y)
        }

        // 绘制多边形沿脊柱法向最多外凸 headWidth/2（箭头外角），会落到
        // 仅按脊柱计算的包围盒之外。这里按样式膨胀，保证 erase/选中
        // 矩形相交测试覆盖所有渲染像素。
        let pad = boundingPad
        return NSRect(
            x: minX - pad,
            y: minY - pad,
            width: maxX - minX + 2 * pad,
            height: maxY - minY + 2 * pad
        )
    }

    private var boundingPad: CGFloat {
        switch style {
        case .tapered:
            return (arrowGeometry?.headWidth ?? 0) / 2
        case .doubleEnded, .line, .dotTail:
            guard let metrics = strokedMetrics else { return lineWidth / 2 }
            return max(metrics.headWidth / 2, metrics.shaftWidth / 2, metrics.tailRadius) + NumberArrowShape.headStrokeWidth + 2
        }
    }

    // MARK: - tapered 几何

    /// draw / containsPoint / boundingRect 共享的缩放几何。
    /// 当箭头退化（长度为 0）时返回 nil。
    private struct ArrowGeometry {
        let length: CGFloat
        let unitX: CGFloat
        let unitY: CGFloat
        let perpX: CGFloat
        let perpY: CGFloat
        let headLength: CGFloat
        let headWidth: CGFloat
        let neckHalf: CGFloat
        let tailHalf: CGFloat
        let neckIndent: CGFloat
    }

    /// tapered 样式用的几何。短箭头按 spanLength 比例整体缩放，
    /// 使头部基线永不越过尾部，多边形保持简单不自交。
    private var arrowGeometry: ArrowGeometry? {
        let dx: CGFloat
        let dy: CGFloat
        if let cp = controlPoint {
            dx = end.x - cp.x
            dy = end.y - cp.y
        } else {
            dx = end.x - start.x
            dy = end.y - start.y
        }
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return nil }

        var headLength: CGFloat = max(22, lineWidth * 6.5)
        var headWidth: CGFloat = max(22, lineWidth * 7.5)
        var neckHalf: CGFloat = max(3, lineWidth * 1.4)
        var tailHalf: CGFloat = max(0.5, lineWidth * 0.25)

        // 短箭头：整体按比例缩放几何，使头基线永不越过尾部，多边形
        // 保持简单而不自交。
        //
        // 用实际跨度（弦 |end - start|）—— 不是 `length`（曲线箭头
        // 的 `length` 只是终点切线模长 |end - cp|），否则把曲线手柄拖
        // 近尖端会把一支长箭头塌缩成细条。
        let spanLength: CGFloat = controlPoint == nil
            ? length
            : hypot(end.x - start.x, end.y - start.y)
        if spanLength > 0 && spanLength < headLength {
            let scale = spanLength / headLength
            headWidth *= scale
            neckHalf *= scale
            tailHalf *= scale
            headLength = spanLength
        }

        let unitX = dx / length
        let unitY = dy / length
        return ArrowGeometry(
            length: length,
            unitX: unitX,
            unitY: unitY,
            perpX: -unitY,
            perpY: unitX,
            headLength: headLength,
            headWidth: headWidth,
            neckHalf: neckHalf,
            tailHalf: tailHalf,
            neckIndent: headLength * 0.14
        )
    }

    // MARK: - stroked 几何（doubleEnded / line / dotTail）

    private struct UnitVector {
        let x: CGFloat
        let y: CGFloat
        let length: CGFloat
    }

    private struct StrokedGeometry {
        let startUnit: UnitVector
        let endUnit: UnitVector
        let spanLength: CGFloat
    }

    private struct StrokedMetrics {
        let headLength: CGFloat
        let headWidth: CGFloat
        let shaftWidth: CGFloat
        let tailRadius: CGFloat
    }

    /// 描边样式的几何：起止端点处的切线方向（直线/曲线）与弦长。
    private var strokedGeometry: StrokedGeometry? {
        let chordDX = end.x - start.x
        let chordDY = end.y - start.y
        let chordLength = hypot(chordDX, chordDY)
        guard chordLength > 0 else { return nil }

        let rawStartDX: CGFloat
        let rawStartDY: CGFloat
        let rawEndDX: CGFloat
        let rawEndDY: CGFloat
        if let cp = controlPoint {
            rawStartDX = cp.x - start.x
            rawStartDY = cp.y - start.y
            rawEndDX = end.x - cp.x
            rawEndDY = end.y - cp.y
        } else {
            rawStartDX = chordDX
            rawStartDY = chordDY
            rawEndDX = chordDX
            rawEndDY = chordDY
        }

        let startUnit = normalized(dx: rawStartDX, dy: rawStartDY)
            ?? normalized(dx: chordDX, dy: chordDY)
        let endUnit = normalized(dx: rawEndDX, dy: rawEndDY)
            ?? normalized(dx: chordDX, dy: chordDY)
        guard let startUnit, let endUnit else { return nil }
        return StrokedGeometry(startUnit: startUnit, endUnit: endUnit, spanLength: chordLength)
    }

    /// 描边样式的度量：按 spanLength 限制头长/头宽，避免短箭头头部越界。
    private var strokedMetrics: StrokedMetrics? {
        guard let geometry = strokedGeometry else { return nil }
        let headLimit = style == .doubleEnded ? 0.34 : 0.46
        guard style != .tapered else { return nil }
        let shaftWidth = max(1, lineWidth)
        var headLength = max(10, shaftWidth * 4)
        var headWidth = max(7, shaftWidth * 3)
        let tailRadius: CGFloat = style == .dotTail ? max(4, shaftWidth + 2) : 0
        headLength = min(headLength, max(4, geometry.spanLength * headLimit))
        headWidth = min(headWidth, max(6, geometry.spanLength * 0.75))
        return StrokedMetrics(
            headLength: headLength,
            headWidth: headWidth,
            shaftWidth: shaftWidth,
            tailRadius: tailRadius
        )
    }

    private func normalized(dx: CGFloat, dy: CGFloat) -> UnitVector? {
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        return UnitVector(x: dx / length, y: dy / length, length: length)
    }

    private func point(_ point: CGPoint, advancedBy distance: CGFloat, along unit: UnitVector) -> CGPoint {
        CGPoint(x: point.x + unit.x * distance, y: point.y + unit.y * distance)
    }

    /// 描边箭杆两端按头长内缩，使头部不与箭杆重叠。两端总内缩超过
    /// spanLength-1 时按比例回缩。
    private func insetSpineEndpoints(
        geometry: StrokedGeometry,
        metrics: StrokedMetrics
    ) -> (start: CGPoint, end: CGPoint) {
        var startInset: CGFloat = 0
        var endInset: CGFloat = metrics.headLength

        if style == .doubleEnded {
            startInset = metrics.headLength
        }

        let totalInset = startInset + endInset
        if totalInset > geometry.spanLength - 1, totalInset > 0 {
            let scale = max(0, geometry.spanLength - 1) / totalInset
            startInset *= scale
            endInset *= scale
        }

        return (
            point(start, advancedBy: startInset, along: geometry.startUnit),
            point(end, advancedBy: -endInset, along: geometry.endUnit)
        )
    }

    /// 直线或二次贝塞尔箭杆路径。
    private func spinePath(from start: CGPoint, to end: CGPoint) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: start)
        if let cp = controlPoint {
            path.addQuadCurve(to: end, control: cp)
        } else {
            path.addLine(to: end)
        }
        return path
    }

    private func arrowHeadPath(
        tip: CGPoint,
        unitX: CGFloat,
        unitY: CGFloat,
        length: CGFloat,
        width: CGFloat
    ) -> CGMutablePath {
        NumberArrowShape.headPath(tip: tip, unitX: unitX, unitY: unitY, length: length, width: width)
    }

    // MARK: - 曲线手柄锚点

    /// 未设置 controlPoint 时曲线手柄的默认视觉位置：start/end 几何中点。
    /// 用于 adjust 模式下锚定曲线手柄。
    var defaultCurveMid: CGPoint {
        CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2
        )
    }

    /// 曲线手柄的渲染位置：设置了 controlPoint 就用它，否则用几何中点。
    var curveHandlePoint: CGPoint {
        controlPoint ?? defaultCurveMid
    }

    // MARK: - 绘制

    func draw(in context: CGContext, bounds: NSRect) {
        switch style {
        case .tapered:
            drawTapered(in: context, bounds: bounds)
        case .doubleEnded, .line, .dotTail:
            drawStroked(in: context, bounds: bounds)
        }
    }

    /// tapered：直线是单条泪滴多边形，曲线是双偏移二次贝塞尔带 + 箭头。
    private func drawTapered(in context: CGContext, bounds: NSRect) {
        guard let g = arrowGeometry else { return }
        context.setFillColor(color.cgColor)

        // 头部基线中点 + 凹颈点（更靠近尖端）。
        let baseX = end.x - g.unitX * g.headLength
        let baseY = end.y - g.unitY * g.headLength
        let neckX = end.x - g.unitX * (g.headLength - g.neckIndent)
        let neckY = end.y - g.unitY * (g.headLength - g.neckIndent)

        // 箭头头部外角。
        let headLX = baseX + g.perpX * g.headWidth / 2
        let headLY = baseY + g.perpY * g.headWidth / 2
        let headRX = baseX - g.perpX * g.headWidth / 2
        let headRY = baseY - g.perpY * g.headWidth / 2

        // 箭杆与头部相接处（凹基线）。
        let neckLX = neckX + g.perpX * g.neckHalf
        let neckLY = neckY + g.perpY * g.neckHalf
        let neckRX = neckX - g.perpX * g.neckHalf
        let neckRY = neckY - g.perpY * g.neckHalf

        if let cp = controlPoint {
            // 曲线箭头：锥形箭杆作为由两条平行偏移二次贝塞尔包围的
            // 填充区域绘制，再把扫出的箭头叠在上面。
            //
            // 精确偏移二次贝塞尔很复杂，但此处宽度很小，可以把三个
            // 控制点各自按该点的局部法线偏移来近似。
            let startDX = cp.x - start.x
            let startDY = cp.y - start.y
            let startLen = max(hypot(startDX, startDY), 0.0001)
            let startPerpX = -startDY / startLen
            let startPerpY = startDX / startLen

            // 控制点处的法线 —— 用弦方向（start → end），即二次贝塞尔
            // 在控制点处的进出切线之和。
            let cpTangentX = end.x - start.x
            let cpTangentY = end.y - start.y
            let cpTangentLen = max(hypot(cpTangentX, cpTangentY), 0.0001)
            let cpPerpX = -cpTangentY / cpTangentLen
            let cpPerpY = cpTangentX / cpTangentLen

            // 控制点处的宽度 —— 在 tailHalf 与 neckHalf 之间线性插值。
            let midHalf = (g.tailHalf + g.neckHalf) * 0.5

            // 用 de Casteljau 截断 cp，使箭杆成为原脊柱曲线 t=0..t≈t_neck
            // 的子贝塞尔。直接用 `cp` 会让箭杆鼓出原二次曲线很多。二次
            // 贝塞尔在端点的速度是 2·(end - cp)，故距尖端 d 的参数步长
            // 是 d/(2·length)。
            let neckDist = g.headLength - g.neckIndent
            let t = max(0, min(1, 1 - neckDist / (2 * g.length)))
            let cpTruncX = start.x + (cp.x - start.x) * t
            let cpTruncY = start.y + (cp.y - start.y) * t

            let tailLX = start.x + startPerpX * g.tailHalf
            let tailLY = start.y + startPerpY * g.tailHalf
            let tailRX = start.x - startPerpX * g.tailHalf
            let tailRY = start.y - startPerpY * g.tailHalf
            let cpLX = cpTruncX + cpPerpX * midHalf
            let cpLY = cpTruncY + cpPerpY * midHalf
            let cpRX = cpTruncX - cpPerpX * midHalf
            let cpRY = cpTruncY - cpPerpY * midHalf

            context.beginPath()
            context.move(to: CGPoint(x: tailLX, y: tailLY))
            context.addQuadCurve(to: CGPoint(x: neckLX, y: neckLY), control: CGPoint(x: cpLX, y: cpLY))
            context.addLine(to: CGPoint(x: neckRX, y: neckRY))
            context.addQuadCurve(to: CGPoint(x: tailRX, y: tailRY), control: CGPoint(x: cpRX, y: cpRY))
            context.closePath()
            context.fillPath()

            // 叠加箭头。
            context.beginPath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: headLX, y: headLY))
            context.addLine(to: CGPoint(x: neckLX, y: neckLY))
            context.addLine(to: CGPoint(x: neckRX, y: neckRY))
            context.addLine(to: CGPoint(x: headRX, y: headRY))
            context.closePath()
            context.fillPath()
        } else {
            // 直线箭头 —— 单个锥形泪滴多边形。尾部细，箭杆向凹颈加宽，
            // 头部再外扩到宽尖端。
            let tailLX = start.x + g.perpX * g.tailHalf
            let tailLY = start.y + g.perpY * g.tailHalf
            let tailRX = start.x - g.perpX * g.tailHalf
            let tailRY = start.y - g.perpY * g.tailHalf

            context.beginPath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: headLX, y: headLY))
            context.addLine(to: CGPoint(x: neckLX, y: neckLY))
            context.addLine(to: CGPoint(x: tailLX, y: tailLY))
            context.addLine(to: CGPoint(x: tailRX, y: tailRY))
            context.addLine(to: CGPoint(x: neckRX, y: neckRY))
            context.addLine(to: CGPoint(x: headRX, y: headRY))
            context.closePath()
            context.fillPath()
        }
    }

    /// doubleEnded / line / dotTail：描边箭杆 + 箭头头部。
    /// doubleEnded 两端都有头；dotTail 在尾部画填充圆点。
    private func drawStroked(in context: CGContext, bounds: NSRect) {
        guard let geometry = strokedGeometry, let metrics = strokedMetrics else { return }
        let endpoints = insetSpineEndpoints(geometry: geometry, metrics: metrics)
        let path = spinePath(from: endpoints.start, to: endpoints.end)

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(metrics.shaftWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()

        NumberArrowShape.drawHead(
            tip: end,
            unitX: geometry.endUnit.x,
            unitY: geometry.endUnit.y,
            length: metrics.headLength,
            width: metrics.headWidth,
            in: context
        )

        if style == .doubleEnded {
            NumberArrowShape.drawHead(
                tip: start,
                unitX: -geometry.startUnit.x,
                unitY: -geometry.startUnit.y,
                length: metrics.headLength,
                width: metrics.headWidth,
                in: context
            )
        } else if style == .dotTail {
            let rect = NSRect(
                x: start.x - metrics.tailRadius,
                y: start.y - metrics.tailRadius,
                width: metrics.tailRadius * 2,
                height: metrics.tailRadius * 2
            )
            context.fillEllipse(in: rect)
        }

        context.restoreGState()
    }

    // MARK: - 命中测试

    func containsPoint(_ point: NSPoint) -> Bool {
        switch style {
        case .tapered:
            return containsTapered(point)
        case .doubleEnded, .line, .dotTail:
            return containsStroked(point)
        }
    }

    /// tapered 命中：精确匹配渲染轮廓 —— 缩放的头部多边形（凹扫箭头）
    /// + 缩放的箭杆多边形（锥形箭身）。小 `grab` 膨胀保证细尾可点中，
    /// 无需给整条脊柱套粗带（那样会在大线宽下漏盖更宽的颈部）。
    private func containsTapered(_ point: CGPoint) -> Bool {
        guard let g = arrowGeometry else { return false }
        let grab: CGFloat = 3

        let baseX = end.x - g.unitX * g.headLength
        let baseY = end.y - g.unitY * g.headLength
        let neckX = end.x - g.unitX * (g.headLength - g.neckIndent)
        let neckY = end.y - g.unitY * (g.headLength - g.neckIndent)

        // 头部多边形 —— 凹扫轮廓，与 draw() 一致。
        let headHalf = g.headWidth / 2 + grab
        let neckHitHalf = g.neckHalf + grab
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: baseX + g.perpX * headHalf, y: baseY + g.perpY * headHalf))
        head.addLine(to: CGPoint(x: neckX + g.perpX * neckHitHalf, y: neckY + g.perpY * neckHitHalf))
        head.addLine(to: CGPoint(x: neckX - g.perpX * neckHitHalf, y: neckY - g.perpY * neckHitHalf))
        head.addLine(to: CGPoint(x: baseX - g.perpX * headHalf, y: baseY - g.perpY * headHalf))
        head.closeSubpath()
        if head.contains(point) {
            return true
        }

        // 箭杆多边形 —— 锥形梯形（直线）或锥形贝塞尔带（曲线）。
        // 与 draw(in:bounds:) 中绘制的几何一致。
        let tailHitHalf = g.tailHalf + grab
        let shaft = CGMutablePath()
        if let cp = controlPoint {
            let startDX = cp.x - start.x
            let startDY = cp.y - start.y
            let startLen = max(hypot(startDX, startDY), 0.0001)
            let startPerpX = -startDY / startLen
            let startPerpY = startDX / startLen

            let cpTangentX = end.x - start.x
            let cpTangentY = end.y - start.y
            let cpTangentLen = max(hypot(cpTangentX, cpTangentY), 0.0001)
            let cpPerpX = -cpTangentY / cpTangentLen
            let cpPerpY = cpTangentX / cpTangentLen

            let midHitHalf = (tailHitHalf + neckHitHalf) * 0.5

            // 与 draw() 一致：截断 cp，使命中测试曲线追踪与渲染箭杆相同
            // 的子贝塞尔，而非原（过度鼓出的）曲线。
            let neckDist = g.headLength - g.neckIndent
            let t = max(0, min(1, 1 - neckDist / (2 * g.length)))
            let cpTruncX = start.x + (cp.x - start.x) * t
            let cpTruncY = start.y + (cp.y - start.y) * t

            shaft.move(to: CGPoint(x: start.x + startPerpX * tailHitHalf,
                                   y: start.y + startPerpY * tailHitHalf))
            shaft.addQuadCurve(
                to: CGPoint(x: neckX + g.perpX * neckHitHalf, y: neckY + g.perpY * neckHitHalf),
                control: CGPoint(x: cpTruncX + cpPerpX * midHitHalf, y: cpTruncY + cpPerpY * midHitHalf)
            )
            shaft.addLine(to: CGPoint(x: neckX - g.perpX * neckHitHalf, y: neckY - g.perpY * neckHitHalf))
            shaft.addQuadCurve(
                to: CGPoint(x: start.x - startPerpX * tailHitHalf,
                            y: start.y - startPerpY * tailHitHalf),
                control: CGPoint(x: cpTruncX - cpPerpX * midHitHalf, y: cpTruncY - cpPerpY * midHitHalf)
            )
            shaft.closeSubpath()
        } else {
            shaft.move(to: CGPoint(x: start.x + g.perpX * tailHitHalf,
                                   y: start.y + g.perpY * tailHitHalf))
            shaft.addLine(to: CGPoint(x: neckX + g.perpX * neckHitHalf, y: neckY + g.perpY * neckHitHalf))
            shaft.addLine(to: CGPoint(x: neckX - g.perpX * neckHitHalf, y: neckY - g.perpY * neckHitHalf))
            shaft.addLine(to: CGPoint(x: start.x - g.perpX * tailHitHalf,
                                      y: start.y - g.perpY * tailHitHalf))
            shaft.closeSubpath()
        }
        return shaft.contains(point)
    }

    /// doubleEnded / line / dotTail 命中：描边膨胀箭杆 + 箭头多边形，
    /// dotTail 用尾部圆点半径 + 4。
    private func containsStroked(_ point: CGPoint) -> Bool {
        guard let geometry = strokedGeometry, let metrics = strokedMetrics else { return false }
        let endpoints = insetSpineEndpoints(geometry: geometry, metrics: metrics)
        let path = spinePath(from: endpoints.start, to: endpoints.end)

        if strokedPathContains(point, path: path, lineWidth: metrics.shaftWidth) {
            return true
        }

        let endHead = arrowHeadPath(
            tip: end,
            unitX: geometry.endUnit.x,
            unitY: geometry.endUnit.y,
            length: metrics.headLength,
            width: metrics.headWidth
        )
        if endHead.contains(point) {
            return true
        }

        if style == .doubleEnded {
            let startHead = arrowHeadPath(
                tip: start,
                unitX: -geometry.startUnit.x,
                unitY: -geometry.startUnit.y,
                length: metrics.headLength,
                width: metrics.headWidth
            )
            return startHead.contains(point)
        }

        if style == .dotTail {
            return hypot(point.x - start.x, point.y - start.y) <= metrics.tailRadius + 4
        }

        return false
    }

    // MARK: - 变换与变异

    func translated(by delta: NSPoint) -> Annotation {
        let translatedCP: CGPoint? = controlPoint.map {
            CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
        return ArrowAnnotation(
            uuid: uuid,
            start: CGPoint(x: start.x + delta.x, y: start.y + delta.y),
            end: CGPoint(x: end.x + delta.x, y: end.y + delta.y),
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: translatedCP
        )
    }

    /// adjust 模式助手：替换（或清空）曲线控制点。
    func withControlPoint(_ cp: CGPoint?) -> ArrowAnnotation {
        var copy = self
        copy.controlPoint = cp
        return copy
    }

    /// adjust 模式助手：替换 start（尾部）端点，保持尖端与曲线控制点
    /// 在画布空间不变。
    func withStart(_ p: CGPoint) -> ArrowAnnotation {
        ArrowAnnotation(
            uuid: uuid,
            start: p,
            end: end,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }

    /// adjust 模式助手：替换尖端（箭头）端点，保持 start 与曲线控制点
    /// 在画布空间不变。
    func withEnd(_ p: CGPoint) -> ArrowAnnotation {
        ArrowAnnotation(
            uuid: uuid,
            start: start,
            end: p,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }

    func withColor(_ color: NSColor) -> Annotation {
        ArrowAnnotation(
            uuid: uuid,
            start: start,
            end: end,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }

    func withLineWidth(_ lineWidth: CGFloat) -> Annotation {
        ArrowAnnotation(
            uuid: uuid,
            start: start,
            end: end,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }

    func withStyle(_ style: ArrowStyle) -> ArrowAnnotation {
        ArrowAnnotation(
            uuid: uuid,
            start: start,
            end: end,
            color: color,
            lineWidth: lineWidth,
            style: style,
            controlPoint: controlPoint
        )
    }
}
