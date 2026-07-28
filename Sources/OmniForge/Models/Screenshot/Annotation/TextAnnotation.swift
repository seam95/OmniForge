import AppKit
import Foundation

/// 文字标注（多行、描边、气泡标注、可拖箭头尾、字号/颜色/旋转）。
///
/// 实现逻辑参照 capcap（`Editor/Annotations.swift` 的 `TextAnnotation`），
/// 保留 OmniForge 的 `uuid`、`Annotation` 协议与 `CGPoint` 几何约束。
/// 气泡模式由独立的 `hasCallout` 开关控制背景，`calloutTip` 仅决定箭头尾巴。
struct TextAnnotation: Annotation, Equatable {
    let uuid: UUID

    /// 文字内容（可含多行 `\n`）。
    var text: String
    /// 编辑/绘制框的底左角，画布坐标。
    var origin: CGPoint
    var color: NSColor
    var fontSize: CGFloat
    var rotation: CGFloat = 0
    /// 描边开关：开启后为字形叠加黑白对比描边，保证在任意背景下可读。
    var hasStroke: Bool = false
    /// 气泡开关：开启后 `color` 变为气泡/箭头填充色，
    /// 字形改用对比色（黑或白）绘制。
    var hasCallout: Bool = false
    /// 气泡箭头尾端（通过选择手柄从气泡拉出）。nil 表示仅气泡无尾巴。
    var calloutTip: CGPoint? = nil

    let supportsRotation: Bool = true

    init(uuid: UUID = UUID(),
         text: String,
         origin: CGPoint,
         color: NSColor = .black,
         fontSize: CGFloat = 18,
         rotation: CGFloat = 0,
         hasStroke: Bool = false,
         hasCallout: Bool = false,
         calloutTip: CGPoint? = nil) {
        self.uuid = uuid
        self.text = text
        self.origin = origin
        self.color = color
        self.fontSize = fontSize
        self.rotation = rotation
        self.hasStroke = hasStroke
        self.hasCallout = hasCallout
        self.calloutTip = calloutTip
    }

    // MARK: - 常量

    /// 行末光标预留宽度，让编辑框右侧留出光标位。
    static let trailingCaretPadding: CGFloat = 12
    /// 编辑框最小宽度，避免空文本时框过窄。
    static let minimumEditorWidth: CGFloat = 32
    /// 气泡左右内边距。
    static let calloutHorizontalPadding: CGFloat = 10
    /// 气泡上下内边距。
    static let calloutVerticalPadding: CGFloat = 4
    /// 气泡圆角半径。
    static let calloutCornerRadius: CGFloat = 7
    /// 无箭头时尾巴手柄相对气泡底部的默认偏移。
    static let calloutHandleOffset: CGFloat = 18
    /// 箭头尾端距气泡锚点的最小距离，小于此值视为无尾巴。
    static let calloutArrowMinDistance: CGFloat = 18
    /// 气泡包围盒命中测试的描边膨胀宽度。
    static let calloutArrowLineWidth: CGFloat = 3
    /// 尾巴根部在气泡边上的最大宽度。
    private static let calloutTailBaseWidth: CGFloat = 30
    /// 尾巴尖端的圆角半径上限。
    private static let calloutTailTipMaxRadius: CGFloat = 3.2
    /// 行内垂直居中修正的权重因子。
    private static let textVerticalCenteringFactor: CGFloat = 0.2

    /// 描边笔宽，以 `NSAttributedString.Key.strokeWidth` 要求的
    /// 字号百分比为单位。覆盖在上方的填充层吃掉内半，可见描边约为该值一半。
    static let strokeWidthPercent: CGFloat = 6.0

    // MARK: - 字体与颜色

    static func font(forSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .bold)
    }

    /// 浅色填充（白/黄/绿）配黑描边，其余填充色配白描边。
    static func strokeColor(for fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .white }
        func matches(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
            abs(rgb.redComponent - r) < 0.04
                && abs(rgb.greenComponent - g) < 0.04
                && abs(rgb.blueComponent - b) < 0.04
        }
        let blackStroke = matches(1.0, 1.0, 1.0)   // 白
            || matches(1.0, 0.8, 0.0)              // 黄
            || matches(0.0, 0.83, 0.42)            // 绿
        return blackStroke ? .black : .white
    }

    static func contrastingTextColor(for background: NSColor) -> NSColor {
        strokeColor(for: background)
    }

    /// 行高 = ceil(ascender - descender + leading)。
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// 将文本按 `\r\n` / `\r` / `\n` 拆分为行数组；空文本返回 `[""]`。
    static func lines(for text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return lines.isEmpty ? [""] : lines
    }

    // MARK: - TextKit 度量

    private static func measuredLineWidth(_ line: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        return ceil((line as NSString).size(withAttributes: attributes).width)
    }

    /// 单行字形的紧贴包围盒（device metrics）。
    /// 空行用占位 "M" 度量以获得稳定的行高基准。
    private static func inkBounds(for line: String, attributes: [NSAttributedString.Key: Any]) -> NSRect {
        let textToMeasure = line.isEmpty ? "M" : line
        return NSAttributedString(string: textToMeasure, attributes: attributes).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesDeviceMetrics]
        )
    }

    /// 基于字形墨迹包围盒的垂直居中修正量（绘制 y 偏移）。
    private static func centeredDrawOffsetY(
        for line: String,
        lineHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let ink = inkBounds(for: line, attributes: attributes)
        let metricOffset = (lineHeight - ink.height) / 2 - ink.origin.y
        return metricOffset * textVerticalCenteringFactor
    }

    /// 编辑框尺寸：宽度 = 最大行宽 + 行末光标预留，高度 = 行高 × 行数。
    static func editorSize(for text: String, font: NSFont) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = Self.lines(for: text)
        let fallbackWidth = ceil(("M" as NSString).size(withAttributes: attrs).width)
        let measuredWidth = lines
            .map { measuredLineWidth($0, attributes: attrs) }
            .max() ?? fallbackWidth
        let lineCount = max(1, lines.count)
        return NSSize(
            width: max(measuredWidth + trailingCaretPadding, minimumEditorWidth),
            height: lineHeight(for: font) * CGFloat(lineCount)
        )
    }

    /// 紧贴字形墨迹的矩形（画布坐标）。
    ///
    /// 用作虚线选区框与旋转枢轴，让 chrome 贴合实际墨迹，
    /// 而非编辑框的行末光标预留 + 行距（后者会让选区偏向文字左下角）。
    var textBounds: NSRect {
        let font = TextAnnotation.font(forSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = TextAnnotation.lines(for: text)
        let lineHeight = TextAnnotation.lineHeight(for: font)
        let rects = lines.enumerated().map { index, line in
            let ink = TextAnnotation.inkBounds(for: line, attributes: attrs)
            let offsetY = TextAnnotation.centeredDrawOffsetY(
                for: line,
                lineHeight: lineHeight,
                attributes: attrs
            )
            return NSRect(
                x: origin.x + ink.origin.x,
                y: origin.y + lineHeight * CGFloat(lines.count - 1 - index) + offsetY + ink.origin.y,
                width: ink.width,
                height: ink.height
            )
        }
        guard let first = rects.first else { return textBlockRect }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// 文本块矩形：宽度为最长行宽（不小于最小编辑宽减预留），高度为行高 × 行数。
    var textBlockRect: NSRect {
        let font = TextAnnotation.font(forSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = TextAnnotation.lines(for: text)
        let measuredWidth = lines
            .map { TextAnnotation.measuredLineWidth($0, attributes: attrs) }
            .max() ?? 0
        let blockHeight = TextAnnotation.lineHeight(for: font) * CGFloat(lines.count)
        let width = max(measuredWidth, TextAnnotation.minimumEditorWidth - TextAnnotation.trailingCaretPadding)
        return NSRect(x: origin.x, y: origin.y, width: width, height: blockHeight)
    }

    /// 气泡主体矩形：文本块四周外扩气泡内边距。
    var calloutBodyRect: NSRect {
        textBlockRect.insetBy(
            dx: -TextAnnotation.calloutHorizontalPadding,
            dy: -TextAnnotation.calloutVerticalPadding
        )
    }

    /// 尾巴手柄点：有箭头尾端时取 `calloutTip`，否则为气泡底部中点下方默认偏移。
    var calloutHandlePoint: CGPoint {
        calloutTip ?? CGPoint(
            x: calloutBodyRect.midX,
            y: calloutBodyRect.minY - TextAnnotation.calloutHandleOffset
        )
    }

    /// 是否绘制箭头尾巴：需开启气泡、设置了尾端、尾端离开气泡体，
    /// 且尾端到锚点距离不小于最小箭头距离。
    var hasCalloutArrow: Bool {
        guard hasCallout, let tip = calloutTip else { return false }
        guard !calloutBodyRect.insetBy(dx: -2, dy: -2).contains(tip) else { return false }
        let anchor = calloutAnchorPoint(for: tip)
        return hypot(tip.x - anchor.x, tip.y - anchor.y) >= TextAnnotation.calloutArrowMinDistance
    }

    /// 非气泡命中矩形：墨迹四周外扩，垂直方向至少半字号。
    var hitBounds: NSRect {
        textBounds.insetBy(dx: -10, dy: -max(10, fontSize * 0.75))
    }

    /// 轴对齐包围盒：非气泡为墨迹矩形；气泡为背景路径包围盒外扩描边宽度。
    var boundingRect: NSRect {
        guard hasCallout else { return textBounds }
        return calloutBackgroundPath().boundingBoxOfPath
            .insetBy(dx: -TextAnnotation.calloutArrowLineWidth, dy: -TextAnnotation.calloutArrowLineWidth)
    }

    // MARK: - 气泡锚点

    func calloutAnchorPoint(for tip: CGPoint?) -> CGPoint {
        calloutAnchorPoint(for: tip, in: calloutBodyRect)
    }

    /// 尾端指向气泡体边界的交点（从中心向尾端射线与矩形的交点）。
    /// 尾端为 nil 或退化方向时回退为底部中点。
    private func calloutAnchorPoint(for tip: CGPoint?, in rect: NSRect) -> CGPoint {
        guard let tip else {
            return CGPoint(x: rect.midX, y: rect.minY)
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = tip.x - center.x
        let dy = tip.y - center.y
        guard dx != 0 || dy != 0 else {
            return CGPoint(x: rect.midX, y: rect.minY)
        }

        let tx: CGFloat = dx > 0
            ? (rect.maxX - center.x) / dx
            : (dx < 0 ? (rect.minX - center.x) / dx : .greatestFiniteMagnitude)
        let ty: CGFloat = dy > 0
            ? (rect.maxY - center.y) / dy
            : (dy < 0 ? (rect.minY - center.y) / dy : .greatestFiniteMagnitude)
        let t = min(tx, ty)
        guard t.isFinite, t > 0 else {
            return CGPoint(x: rect.midX, y: rect.minY)
        }
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    // MARK: - 绘制

    func draw(in context: CGContext, bounds: NSRect) {
        let font = TextAnnotation.font(forSize: fontSize)
        let lines = TextAnnotation.lines(for: text)
        let lineHeight = TextAnnotation.lineHeight(for: font)
        NSGraphicsContext.saveGraphicsState()
        if hasCallout {
            drawCalloutBackground(in: context)
        }
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: hasCallout ? TextAnnotation.contrastingTextColor(for: color) : color,
            .font: font
        ]
        let strokeAttributes: [NSAttributedString.Key: Any]? = {
            // 气泡模式下字形已用对比色填充，不再额外描边。
            guard hasStroke, !hasCallout else { return nil }
            let stroke = TextAnnotation.strokeColor(for: color)
            return [
                .foregroundColor: stroke,
                .strokeColor: stroke,
                .strokeWidth: -TextAnnotation.strokeWidthPercent,
                .font: font
            ]
        }()

        for (index, line) in lines.enumerated() where !line.isEmpty {
            let offsetY = TextAnnotation.centeredDrawOffsetY(
                for: line,
                lineHeight: lineHeight,
                attributes: fillAttributes
            )
            let lineOrigin = CGPoint(
                x: origin.x,
                y: origin.y + lineHeight * CGFloat(lines.count - 1 - index) + offsetY
            )
            if let strokeAttributes {
                (line as NSString).draw(at: lineOrigin, withAttributes: strokeAttributes)
            }
            (line as NSString).draw(at: lineOrigin, withAttributes: fillAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 气泡背景路径

    /// 仅绘制气泡背景（不含字形），供独立绘制场景使用。
    func drawCalloutBackgroundOnly(in context: CGContext, bodyRect: NSRect? = nil) {
        guard hasCallout else { return }
        drawCalloutBackground(in: context, bodyRect: bodyRect ?? calloutBodyRect)
    }

    private func drawCalloutBackground(in context: CGContext, bodyRect: NSRect? = nil) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(calloutBackgroundPath(bodyRect: bodyRect ?? calloutBodyRect))
        context.fillPath()
        context.restoreGState()
    }

    private func calloutBackgroundPath() -> CGPath {
        calloutBackgroundPath(bodyRect: calloutBodyRect)
    }

    private func calloutBackgroundPath(bodyRect: NSRect) -> CGPath {
        guard hasCalloutArrow, let tip = calloutTip else {
            return CGPath(
                roundedRect: bodyRect,
                cornerWidth: TextAnnotation.calloutCornerRadius,
                cornerHeight: TextAnnotation.calloutCornerRadius,
                transform: nil
            )
        }
        return calloutBubblePath(to: tip, bodyRect: bodyRect)
    }

    /// 圆角矩形 + 尾巴的完整贝塞尔气泡路径。
    /// 四条边按矩形周长顺序（底→右→上→左）行进，尾巴插入其所在边的圆角之间。
    private func calloutBubblePath(to tip: CGPoint, bodyRect rect: NSRect) -> CGPath {
        let radius = min(TextAnnotation.calloutCornerRadius, rect.width / 2, rect.height / 2)
        guard radius > 0 else {
            return CGPath(
                rect: rect,
                transform: nil
            )
        }

        let base = calloutTailBase(for: tip, in: rect)
        let path = CGMutablePath()
        let kappa: CGFloat = 0.552_284_749_830_793_6
        let k = radius * kappa

        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        path.move(to: CGPoint(x: minX + radius, y: minY))
        addBottomEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + radius),
            control1: CGPoint(x: maxX - radius + k, y: minY),
            control2: CGPoint(x: maxX, y: minY + radius - k)
        )
        addRightEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: CGPoint(x: maxX - radius, y: maxY),
            control1: CGPoint(x: maxX, y: maxY - radius + k),
            control2: CGPoint(x: maxX - radius + k, y: maxY)
        )
        addTopEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: CGPoint(x: minX, y: maxY - radius),
            control1: CGPoint(x: minX + radius - k, y: maxY),
            control2: CGPoint(x: minX, y: maxY - radius + k)
        )
        addLeftEdge(to: path, rect: rect, radius: radius, base: base, tip: tip)
        path.addCurve(
            to: CGPoint(x: minX + radius, y: minY),
            control1: CGPoint(x: minX, y: minY + radius - k),
            control2: CGPoint(x: minX + radius - k, y: minY)
        )
        path.closeSubpath()
        return path
    }

    private func addBottomEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: CGPoint
    ) {
        if base.side == .bottom {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    }

    private func addRightEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: CGPoint
    ) {
        if base.side == .right {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
    }

    private func addTopEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: CGPoint
    ) {
        if base.side == .top {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    }

    private func addLeftEdge(
        to path: CGMutablePath,
        rect: NSRect,
        radius: CGFloat,
        base: CalloutTailBase,
        tip: CGPoint
    ) {
        if base.side == .left {
            path.addLine(to: base.start)
            appendCalloutTail(to: tip, base: base, in: path)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    }

    /// 在当前路径上追加尾巴：根部两侧圆角过渡，尖端圆头，
    /// 由四段三次贝塞尔曲线构成（根→侧腰→尖→侧腰→根）。
    private func appendCalloutTail(to tip: CGPoint, base: CalloutTailBase, in path: CGMutablePath) {
        let dx = tip.x - base.center.x
        let dy = tip.y - base.center.y
        let distance = hypot(dx, dy)
        guard distance >= TextAnnotation.calloutArrowMinDistance else { return }
        let unitX = dx / distance
        let unitY = dy / distance
        let perpX = -unitY
        let perpY = unitX
        let tipRadius = min(
            TextAnnotation.calloutTailTipMaxRadius,
            max(1.25, fontSize * 0.05),
            distance * 0.08
        )
        let rootRound = min(max(5, fontSize * 0.22), base.halfWidth * 0.72, distance * 0.22)
        let sideControl = max(rootRound, distance * 0.32)

        let tipBack = CGPoint(x: tip.x - unitX * tipRadius, y: tip.y - unitY * tipRadius)
        let negativePerpTip = CGPoint(x: tipBack.x - perpX * tipRadius, y: tipBack.y - perpY * tipRadius)
        let positivePerpTip = CGPoint(x: tipBack.x + perpX * tipRadius, y: tipBack.y + perpY * tipRadius)
        let tangentDotPerp = base.tangent.dx * perpX + base.tangent.dy * perpY
        let startTip: CGPoint
        let endTip: CGPoint
        let startTipSide: CGVector
        let endTipSide: CGVector
        if tangentDotPerp >= 0 {
            startTip = negativePerpTip
            endTip = positivePerpTip
            startTipSide = CGVector(dx: -perpX, dy: -perpY)
            endTipSide = CGVector(dx: perpX, dy: perpY)
        } else {
            startTip = positivePerpTip
            endTip = negativePerpTip
            startTipSide = CGVector(dx: perpX, dy: perpY)
            endTipSide = CGVector(dx: -perpX, dy: -perpY)
        }
        let roundedTipControl = tipRadius * 0.55

        path.addCurve(
            to: startTip,
            control1: CGPoint(
                x: base.start.x + base.tangent.dx * rootRound,
                y: base.start.y + base.tangent.dy * rootRound
            ),
            control2: CGPoint(
                x: startTip.x - unitX * sideControl,
                y: startTip.y - unitY * sideControl
            )
        )
        path.addCurve(
            to: tip,
            control1: CGPoint(
                x: startTip.x + unitX * roundedTipControl,
                y: startTip.y + unitY * roundedTipControl
            ),
            control2: CGPoint(
                x: tip.x + startTipSide.dx * roundedTipControl,
                y: tip.y + startTipSide.dy * roundedTipControl
            )
        )
        path.addCurve(
            to: endTip,
            control1: CGPoint(
                x: tip.x + endTipSide.dx * roundedTipControl,
                y: tip.y + endTipSide.dy * roundedTipControl
            ),
            control2: CGPoint(
                x: endTip.x + unitX * roundedTipControl,
                y: endTip.y + unitY * roundedTipControl
            )
        )
        path.addCurve(
            to: base.end,
            control1: CGPoint(
                x: endTip.x - unitX * sideControl,
                y: endTip.y - unitY * sideControl
            ),
            control2: CGPoint(
                x: base.end.x - base.tangent.dx * rootRound,
                y: base.end.y - base.tangent.dy * rootRound
            )
        )
    }

    // MARK: - 尾巴根部计算

    /// 尾巴根部信息：中心、起止点、沿边切向、半宽、所在边。
    private struct CalloutTailBase {
        let center: CGPoint
        let start: CGPoint
        let end: CGPoint
        let tangent: CGVector
        let halfWidth: CGFloat
        let side: CalloutTailSide
    }

    private enum CalloutTailSide {
        case top
        case right
        case bottom
        case left
    }

    /// 计算尾巴根部：以尾端方向最近的边为附着边，
    /// 根部宽度按字号缩放并钳制在可用跨度内，居中于锚点投影。
    private func calloutTailBase(for tip: CGPoint, in rect: NSRect) -> CalloutTailBase {
        let anchor = calloutAnchorPoint(for: tip, in: rect)
        let side = calloutTailSide(for: anchor, tip: tip, in: rect)
        let desiredWidth = min(
            TextAnnotation.calloutTailBaseWidth,
            max(18, fontSize * 0.78)
        )
        let inset = TextAnnotation.calloutCornerRadius + 1

        let rawTangent: CGVector
        let availableSpan: CGFloat
        let center: CGPoint
        switch side {
        case .top:
            rawTangent = CGVector(dx: -1, dy: 0)
            availableSpan = max(2, rect.width - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = CGPoint(
                x: min(max(anchor.x, rect.minX + inset + half), rect.maxX - inset - half),
                y: rect.maxY
            )
        case .bottom:
            rawTangent = CGVector(dx: 1, dy: 0)
            availableSpan = max(2, rect.width - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = CGPoint(
                x: min(max(anchor.x, rect.minX + inset + half), rect.maxX - inset - half),
                y: rect.minY
            )
        case .left:
            rawTangent = CGVector(dx: 0, dy: -1)
            availableSpan = max(2, rect.height - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = CGPoint(
                x: rect.minX,
                y: min(max(anchor.y, rect.minY + inset + half), rect.maxY - inset - half)
            )
        case .right:
            rawTangent = CGVector(dx: 0, dy: 1)
            availableSpan = max(2, rect.height - inset * 2)
            let half = min(desiredWidth / 2, availableSpan / 2)
            center = CGPoint(
                x: rect.maxX,
                y: min(max(anchor.y, rect.minY + inset + half), rect.maxY - inset - half)
            )
        }

        let halfWidth = min(desiredWidth / 2, availableSpan / 2)

        return CalloutTailBase(
            center: center,
            start: CGPoint(x: center.x - rawTangent.dx * halfWidth, y: center.y - rawTangent.dy * halfWidth),
            end: CGPoint(x: center.x + rawTangent.dx * halfWidth, y: center.y + rawTangent.dy * halfWidth),
            tangent: rawTangent,
            halfWidth: halfWidth,
            side: side
        )
    }

    /// 选择尾巴附着边：取锚点到四条边的最小距离所在边；
    /// 距离并列时按尾端相对中心的水平/垂直主导方向定左右或上下。
    private func calloutTailSide(for anchor: CGPoint, tip: CGPoint, in rect: NSRect) -> CalloutTailSide {
        let distances: [(CalloutTailSide, CGFloat)] = [
            (.top, abs(anchor.y - rect.maxY)),
            (.right, abs(anchor.x - rect.maxX)),
            (.bottom, abs(anchor.y - rect.minY)),
            (.left, abs(anchor.x - rect.minX))
        ]
        let minDistance = distances.map(\.1).min() ?? 0
        let candidates = distances.filter { abs($0.1 - minDistance) < 0.5 }.map(\.0)
        guard candidates.count > 1 else {
            return candidates.first ?? .bottom
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = tip.x - center.x
        let dy = tip.y - center.y
        if abs(dx) > abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .top : .bottom
    }

    // MARK: - 命中测试

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        if hasCallout {
            return calloutBackgroundPath().contains(p)
                || calloutBodyRect.insetBy(dx: -4, dy: -4).contains(p)
        }
        return hitBounds.contains(p)
    }

    // MARK: - 平移

    func translated(by delta: NSPoint) -> Annotation {
        TextAnnotation(
            uuid: uuid,
            text: text,
            origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        )
    }

    /// 平移气泡体但保持箭头尾端不动（仅当存在箭头尾巴时）。
    func translatedBodyPreservingCalloutTip(by delta: NSPoint) -> TextAnnotation {
        TextAnnotation(
            uuid: uuid,
            text: text,
            origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: hasCalloutArrow ? calloutTip : calloutTip.map {
                CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
        )
    }

    // MARK: - 样式变异器

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }

    func withColor(_ color: NSColor) -> Annotation {
        TextAnnotation(
            uuid: uuid,
            text: text,
            origin: origin,
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip
        )
    }

    /// 返回描边开关切换后的副本。
    func withStroke(_ hasStroke: Bool) -> TextAnnotation {
        var copy = self
        copy.hasStroke = hasStroke
        return copy
    }

    /// 返回气泡开关切换后的副本。
    func withCallout(_ hasCallout: Bool) -> TextAnnotation {
        var copy = self
        copy.hasCallout = hasCallout
        return copy
    }

    /// 返回更新尾巴尾端后的副本。
    func withCalloutTip(_ tip: CGPoint?) -> TextAnnotation {
        var copy = self
        copy.calloutTip = tip
        return copy
    }

    /// 改变字号。
    ///
    /// 视觉顶左锚点保持不变——字号在画布坐标中向下生长，
    /// 故 origin 按文本块高度差下移以稳定字头位置。
    func withFontSize(_ fontSize: CGFloat) -> Annotation {
        let oldFont = TextAnnotation.font(forSize: self.fontSize)
        let newFont = TextAnnotation.font(forSize: fontSize)
        let oldHeight = TextAnnotation.editorSize(for: text, font: oldFont).height
        let newHeight = TextAnnotation.editorSize(for: text, font: newFont).height
        let newOrigin = CGPoint(x: origin.x, y: origin.y + (oldHeight - newHeight))
        return TextAnnotation(
            uuid: uuid,
            text: text,
            origin: newOrigin,
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            hasStroke: hasStroke,
            hasCallout: hasCallout,
            calloutTip: calloutTip
        )
    }
}
