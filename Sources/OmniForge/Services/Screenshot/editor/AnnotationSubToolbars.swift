import AppKit

// MARK: - HUD 滑块

/// 圆角轨道 + 强调绿拇指的浮层滑块。参照 capcap `HUDSlider` 的视觉。
final class HUDSlider: NSSlider {
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?

    static let preferredHeight: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
    }

    override func mouseDown(with event: NSEvent) {
        onEditingBegan?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        onEditingEnded?()
        super.mouseUp(with: event)
    }
}

// MARK: - HUD 复选框

/// 带标题的浮层复选框。参照 capcap `HUDCheckboxButton`：自画勾选框 + 标签。
final class HUDCheckboxButton: NSButton {
    init(frame: NSRect, title: String, target: AnyObject?, action: Selector) {
        super.init(frame: frame)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.switch)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 色板

/// 调色板色点。参照 capcap `ColorSwatchView`（paletteDot 风格）。
/// 选中时画强调绿环；白/灰加细边以区别背景。
final class ColorSwatchView: NSView {
    let color: NSColor
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }
    /// 给识别手势用的索引。
    var itemIndex: Int = 0

    init(frame: NSRect, color: NSColor, isSelected: Bool) {
        self.color = color
        self.isSelected = isSelected
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isSelected ? 1 : 2
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        color.setFill()
        path.fill()

        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds)
            EditorHUD.accentGreen.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }

        if color == .white || color == NSColor(white: 0.5, alpha: 1.0) {
            let border = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.gray.withAlphaComponent(0.3).setStroke()
            border.lineWidth = 0.5
            border.stroke()
        }
    }
}

// MARK: - 子工具栏共享

/// 子工具栏通用绘制：圆角8 HUD 背景。
private func drawSubToolbarBackground(_ dirtyRect: NSRect, in view: NSView) {
    let path = NSBezierPath(roundedRect: view.bounds.insetBy(dx: 2, dy: 2),
                            xRadius: EditorHUD.cornerRadius,
                            yRadius: EditorHUD.cornerRadius)
    EditorHUD.toolbarBackground().setFill()
    path.fill()
}

private func makeSeparator(in bounds: NSRect) -> NSView {
    let sep = NSView(frame: NSRect(x: 0, y: 6, width: 1, height: bounds.height - 12))
    sep.wantsLayer = true
    sep.layer?.backgroundColor = EditorHUD.separator().cgColor
    return sep
}

private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
    guard let ac = a.usingColorSpace(.deviceRGB), let bc = b.usingColorSpace(.deviceRGB) else {
        return false
    }
    return abs(ac.redComponent - bc.redComponent) < 0.01 &&
           abs(ac.greenComponent - bc.greenComponent) < 0.01 &&
           abs(ac.blueComponent - bc.blueComponent) < 0.01
}

// MARK: - ColorSizeSubToolbar

/// 颜色 + 尺寸子工具栏。pen/line/arrow/rectangle/ellipse 共用，按需
/// 追加箭头样式、形状填充模式、形状描边样式区段。
/// 参照 capcap `ColorSizeSubToolbar`（L3765-4095）。
final class ColorSizeSubToolbar: NSView {
    // 回调
    var onColorChanged: ((NSColor) -> Void)?
    var onSizeBegan: (() -> Void)?
    var onSizeChanged: ((CGFloat) -> Void)?
    var onSizeEnded: (() -> Void)?
    var onArrowStyleChanged: ((ArrowStyle) -> Void)?
    var onShapeFillModeChanged: ((ShapeFillMode) -> Void)?
    var onShapeStrokeStyleChanged: ((ShapeStrokeStyle) -> Void)?

    private var sizeSlider: HUDSlider?
    private var colorButtons: [ColorSwatchView] = []

    private let sizes: [CGFloat]
    private let sizeMin: CGFloat
    private let sizeMax: CGFloat
    private let dynamicColor: NSColor?
    private let baseColors = EditorStyleDefaults.paletteColors
    private var colors: [NSColor] {
        guard let dynamicColor else { return baseColors }
        return baseColors + [dynamicColor]
    }

    private let showsArrowStyle: Bool
    private let showsShapeFill: Bool
    private let showsShapeStroke: Bool

    // 布局常量（参照 capcap）
    private static let leadingPad: CGFloat = 12
    private static let sizeSliderWidth: CGFloat = 136
    private static let swatchSize: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let separatorGap: CGFloat = 6
    private static let sectionGap: CGFloat = 8
    private static let controlHeight: CGFloat = 20
    private static let controlWidth: CGFloat = 27
    private static let controlGap: CGFloat = 4
    private static let trailingPad: CGFloat = 12

    static func preferredWidth(sizes: [CGFloat],
                               dynamicColor: NSColor?,
                               showsArrowStyle: Bool = false,
                               showsShapeFill: Bool = false,
                               showsShapeStroke: Bool = false) -> CGFloat {
        var x = leadingPad
        if !sizes.isEmpty {
            x += sizeSliderWidth + 8 + 1 + 9
        }
        let colorCount = CGFloat(EditorStyleDefaults.paletteColors.count) + (dynamicColor == nil ? 0 : 1)
        x += colorCount * swatchSize + max(colorCount - 1, 0) * swatchGap

        if showsArrowStyle {
            let n = CGFloat(ArrowStyle.allCases.count)
            x += separatorGap + 1 + sectionGap + n * controlWidth + max(n - 1, 0) * controlGap
        }
        if showsShapeFill {
            x += separatorGap + 1 + sectionGap + 54 // segmented 控件估值
        }
        if showsShapeStroke {
            let n = CGFloat(ShapeStrokeStyle.allCases.count)
            x += separatorGap + 1 + sectionGap + n * controlWidth + max(n - 1, 0) * controlGap
        }
        return ceil(x + trailingPad)
    }

    init(frame: NSRect,
         sizes: [CGFloat],
         currentColor: NSColor,
         dynamicColor: NSColor? = nil,
         currentSize: CGFloat,
         sizeMin: CGFloat,
         sizeMax: CGFloat,
         arrowStyle: ArrowStyle? = nil,
         shapeFillMode: ShapeFillMode? = nil,
         shapeStrokeStyle: ShapeStrokeStyle? = nil) {
        self.sizes = sizes
        self.sizeMin = sizeMin
        self.sizeMax = max(sizeMin, sizeMax)
        self.dynamicColor = dynamicColor
        self.showsArrowStyle = arrowStyle != nil
        self.showsShapeFill = shapeFillMode != nil
        self.showsShapeStroke = shapeStrokeStyle != nil
        super.init(frame: frame)
        setup(currentColor: currentColor,
              currentSize: min(max(currentSize, self.sizeMin), self.sizeMax),
              arrowStyle: arrowStyle,
              shapeFillMode: shapeFillMode,
              shapeStrokeStyle: shapeStrokeStyle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup(currentColor: NSColor,
                       currentSize: CGFloat,
                       arrowStyle: ArrowStyle?,
                       shapeFillMode: ShapeFillMode?,
                       shapeStrokeStyle: ShapeStrokeStyle?) {
        var x = Self.leadingPad
        let midY = bounds.midY

        // 尺寸滑块
        if !sizes.isEmpty {
            let slider = HUDSlider(frame: NSRect(
                x: x,
                y: midY - HUDSlider.preferredHeight / 2,
                width: Self.sizeSliderWidth,
                height: HUDSlider.preferredHeight
            ))
            slider.minValue = Double(sizeMin)
            slider.maxValue = Double(sizeMax)
            slider.doubleValue = Double(currentSize)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sizeSliderChanged(_:))
            slider.onEditingBegan = { [weak self] in self?.onSizeBegan?() }
            slider.onEditingEnded = { [weak self] in self?.onSizeEnded?() }
            slider.toolTip = "Line Width"
            addSubview(slider)
            sizeSlider = slider
            x += Self.sizeSliderWidth
        }

        if !sizes.isEmpty {
            x += Self.separatorGap
            let sep = makeSeparator(in: bounds)
            sep.frame.origin.x = x
            addSubview(sep)
            x += 1 + Self.sectionGap
        }

        // 色板
        let swatchSize = Self.swatchSize
        for (i, color) in colors.enumerated() {
            let swatch = ColorSwatchView(
                frame: NSRect(x: x, y: midY - swatchSize / 2, width: swatchSize, height: swatchSize),
                color: color,
                isSelected: colorsMatch(color, currentColor)
            )
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(colorTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            colorButtons.append(swatch)
            x += swatchSize + Self.swatchGap
        }

        var lastRight = x - Self.swatchGap

        // 箭头样式区
        if showsArrowStyle {
            let sepX = lastRight + Self.separatorGap
            let sep = makeSeparator(in: bounds)
            sep.frame.origin.x = sepX
            addSubview(sep)
            x = sepX + 1 + Self.sectionGap
            for style in ArrowStyle.allCases {
                let btn = makeMiniButton(
                    at: NSRect(x: x, y: midY - Self.controlHeight / 2,
                               width: Self.controlWidth, height: Self.controlHeight),
                    isSelected: style == arrowStyle,
                    label: arrowLabel(style)
                )
                btn.toolTip = arrowLabel(style)
                btn.selectionIndex = ArrowStyle.allCases.firstIndex(of: style) ?? 0
                let click = NSClickGestureRecognizer(target: self, action: #selector(arrowStyleTapped(_:)))
                btn.addGestureRecognizer(click)
                addSubview(btn)
                x += Self.controlWidth + Self.controlGap
            }
            lastRight = x - Self.controlGap
        }

        // 形状填充区
        if showsShapeFill {
            let sepX = lastRight + Self.separatorGap
            let sep = makeSeparator(in: bounds)
            sep.frame.origin.x = sepX
            addSubview(sep)
            x = sepX + 1 + Self.sectionGap
            for mode in ShapeFillMode.allCases {
                let btn = makeMiniButton(
                    at: NSRect(x: x, y: midY - Self.controlHeight / 2,
                               width: Self.controlWidth, height: Self.controlHeight),
                    isSelected: mode == shapeFillMode,
                    label: fillModeLabel(mode)
                )
                btn.selectionIndex = ShapeFillMode.allCases.firstIndex(of: mode) ?? 0
                let click = NSClickGestureRecognizer(target: self, action: #selector(shapeFillTapped(_:)))
                btn.addGestureRecognizer(click)
                addSubview(btn)
                x += Self.controlWidth + Self.controlGap
            }
            lastRight = x - Self.controlGap
        }

        // 形状描边样式区
        if showsShapeStroke {
            let sepX = lastRight + Self.separatorGap
            let sep = makeSeparator(in: bounds)
            sep.frame.origin.x = sepX
            addSubview(sep)
            x = sepX + 1 + Self.sectionGap
            for style in ShapeStrokeStyle.allCases {
                let btn = makeMiniButton(
                    at: NSRect(x: x, y: midY - Self.controlHeight / 2,
                               width: Self.controlWidth, height: Self.controlHeight),
                    isSelected: style == shapeStrokeStyle,
                    label: strokeStyleLabel(style)
                )
                btn.selectionIndex = ShapeStrokeStyle.allCases.firstIndex(of: style) ?? 0
                let click = NSClickGestureRecognizer(target: self, action: #selector(shapeStrokeTapped(_:)))
                btn.addGestureRecognizer(click)
                addSubview(btn)
                x += Self.controlWidth + Self.controlGap
            }
        }
    }

    private func makeMiniButton(at frame: NSRect, isSelected: Bool, label: String) -> MiniChoiceButton {
        MiniChoiceButton(frame: frame, label: label, isSelected: isSelected)
    }

    private func arrowLabel(_ style: ArrowStyle) -> String {
        switch style {
        case .tapered: return "➤"
        case .doubleEnded: return "⇄"
        case .line: return "→"
        case .dotTail: return "●→"
        }
    }

    private func fillModeLabel(_ mode: ShapeFillMode) -> String {
        switch mode {
        case .none: return "▢"
        case .opaque: return "▣"
        case .translucent: return "◱"
        }
    }

    private func strokeStyleLabel(_ style: ShapeStrokeStyle) -> String {
        switch style {
        case .standard: return "━"
        case .rounded: return "◜"
        case .handDrawn: return "∿"
        }
    }

    @objc private func sizeSliderChanged(_ sender: HUDSlider) {
        let value = min(max(CGFloat(sender.doubleValue), sizeMin), sizeMax)
        onSizeChanged?(value)
    }

    @objc private func colorTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? ColorSwatchView else { return }
        let index = view.itemIndex
        guard index < colors.count else { return }
        let color = colors[index]
        for (i, v) in colorButtons.enumerated() where i < colors.count {
            v.isSelected = colorsMatch(colors[i], color)
        }
        onColorChanged?(color)
    }

    @objc private func arrowStyleTapped(_ gesture: NSGestureRecognizer) {
        guard let btn = gesture.view as? MiniChoiceButton else { return }
        let idx = btn.selectionIndex
        guard idx >= 0, idx < ArrowStyle.allCases.count else { return }
        onArrowStyleChanged?(ArrowStyle.allCases[idx])
    }

    @objc private func shapeFillTapped(_ gesture: NSGestureRecognizer) {
        guard let btn = gesture.view as? MiniChoiceButton else { return }
        let idx = btn.selectionIndex
        guard idx >= 0, idx < ShapeFillMode.allCases.count else { return }
        onShapeFillModeChanged?(ShapeFillMode.allCases[idx])
    }

    @objc private func shapeStrokeTapped(_ gesture: NSGestureRecognizer) {
        guard let btn = gesture.view as? MiniChoiceButton else { return }
        let idx = btn.selectionIndex
        guard idx >= 0, idx < ShapeStrokeStyle.allCases.count else { return }
        onShapeStrokeStyleChanged?(ShapeStrokeStyle.allCases[idx])
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSubToolbarBackground(dirtyRect, in: self)
    }
}

/// 子工具栏里的小型可选项（箭头/填充/描边样式等）：选中绿框。
final class MiniChoiceButton: NSView {
    private let label: String
    /// 该项在所属枚举中的索引，供手势识别回读。
    var selectionIndex: Int = 0
    var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, label: String, isSelected: Bool) {
        self.label = label
        self.isSelected = isSelected
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = isSelected ? EditorHUD.accentGreen : .secondaryLabelColor
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (label as NSString).size(withAttributes: attr)
        let origin = NSPoint(x: round(bounds.midX - size.width / 2),
                             y: round(bounds.midY - size.height / 2))
        (label as NSString).draw(at: origin, withAttributes: attr)
        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            EditorHUD.accentGreen.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

// MARK: - TextSubToolbar

/// 文字子工具栏：字号滑块 + 色板 + 描边/背景填充复选框。
/// 参照 capcap `TextSubToolbar`（L4196-4450）。
final class TextSubToolbar: NSView {
    var onColorChanged: ((NSColor) -> Void)?
    var onFontSizeBegan: (() -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onFontSizeEnded: (() -> Void)?
    var onStrokeChanged: ((Bool) -> Void)?
    var onCalloutChanged: ((Bool) -> Void)?

    private var colorButtons: [ColorSwatchView] = []
    private var fontSizeMin: CGFloat
    private var fontSizeMax: CGFloat

    private let dynamicColor: NSColor?
    private let baseColors = EditorStyleDefaults.paletteColors
    private var colors: [NSColor] {
        guard let dynamicColor else { return baseColors }
        return baseColors + [dynamicColor]
    }

    private static let sliderWidth: CGFloat = 150
    private static let swatchSize: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let sectionGap: CGFloat = 8
    private static let checkboxGap: CGFloat = 8
    private static let leadingPad: CGFloat = 12
    private static let sliderSeparatorGap: CGFloat = 8
    private static let paletteLeadingGap: CGFloat = 9
    private static let trailingPad: CGFloat = 12

    /// 根据实际标签宽度计算文字子工具栏所需宽度，避免本地化文案挤出浮层。
    static func preferredWidth(strokeLabel: String,
                               calloutLabel: String,
                               dynamicColor: NSColor? = nil) -> CGFloat {
        let colorCount = CGFloat(EditorStyleDefaults.paletteColors.count + (dynamicColor == nil ? 0 : 1))
        let paletteWidth = colorCount * swatchSize + max(colorCount - 1, 0) * swatchGap

        let controlsWidth = sliderWidth
            + sliderSeparatorGap
            + 1
            + paletteLeadingGap
            + paletteWidth
            + sectionGap
            + 1
            + checkboxGap
            + Self.checkboxWidth(title: strokeLabel)
            + checkboxGap
            + Self.checkboxWidth(title: calloutLabel)

        return ceil(leadingPad + controlsWidth + trailingPad)
    }

    init(frame: NSRect,
         currentColor: NSColor,
         currentFontSize: CGFloat,
         dynamicColor: NSColor? = nil,
         strokeEnabled: Bool,
         calloutEnabled: Bool,
         fontSizeMin: CGFloat = EditorStyleDefaults.fontSizeMin,
         fontSizeMax: CGFloat = EditorStyleDefaults.fontSizeMax,
         strokeLabel: String,
         calloutLabel: String) {
        self.dynamicColor = dynamicColor
        self.fontSizeMin = fontSizeMin
        self.fontSizeMax = max(fontSizeMin, fontSizeMax)
        super.init(frame: frame)
        setup(currentColor: currentColor,
              currentFontSize: min(max(currentFontSize, self.fontSizeMin), self.fontSizeMax),
              strokeEnabled: strokeEnabled,
              calloutEnabled: calloutEnabled,
              strokeLabel: strokeLabel,
              calloutLabel: calloutLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup(currentColor: NSColor,
                       currentFontSize: CGFloat,
                       strokeEnabled: Bool,
                       calloutEnabled: Bool,
                       strokeLabel: String,
                       calloutLabel: String) {
        var x = Self.leadingPad
        let midY = bounds.midY

        // 字号滑块
        let slider = HUDSlider(frame: NSRect(
            x: x, y: midY - HUDSlider.preferredHeight / 2,
            width: TextSubToolbar.sliderWidth, height: HUDSlider.preferredHeight
        ))
        slider.minValue = Double(fontSizeMin)
        slider.maxValue = Double(fontSizeMax)
        slider.doubleValue = Double(currentFontSize)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(fontSizeChanged(_:))
        slider.onEditingBegan = { [weak self] in self?.onFontSizeBegan?() }
        slider.onEditingEnded = { [weak self] in self?.onFontSizeEnded?() }
        slider.toolTip = "Font Size"
        addSubview(slider)
        x += Self.sliderWidth + Self.sliderSeparatorGap

        // 分隔
        let sep = makeSeparator(in: bounds)
        sep.frame.origin.x = x
        addSubview(sep)
        x += 1 + Self.paletteLeadingGap

        // 色板
        let swatchSize = TextSubToolbar.swatchSize
        for (i, color) in colors.enumerated() {
            let swatch = ColorSwatchView(
                frame: NSRect(x: x, y: midY - swatchSize / 2, width: swatchSize, height: swatchSize),
                color: color,
                isSelected: colorsMatch(color, currentColor)
            )
            swatch.itemIndex = i
            let click = NSClickGestureRecognizer(target: self, action: #selector(colorTapped(_:)))
            swatch.addGestureRecognizer(click)
            addSubview(swatch)
            colorButtons.append(swatch)
            x += swatchSize + TextSubToolbar.swatchGap
        }

        let lastRight = x - TextSubToolbar.swatchGap
        let strokeSepX = lastRight + TextSubToolbar.sectionGap
        let strokeSep = makeSeparator(in: bounds)
        strokeSep.frame.origin.x = strokeSepX
        addSubview(strokeSep)
        x = strokeSepX + 1 + TextSubToolbar.checkboxGap

        // 描边复选框
        let strokeCheckbox = HUDCheckboxButton(
            frame: NSRect(x: x, y: midY - 10,
                          width: Self.checkboxWidth(title: strokeLabel), height: 20),
            title: strokeLabel, target: self, action: #selector(strokeToggled(_:))
        )
        strokeCheckbox.state = strokeEnabled ? .on : .off
        addSubview(strokeCheckbox)
        x = strokeCheckbox.frame.maxX + TextSubToolbar.checkboxGap

        // 气泡复选框
        let calloutCheckbox = HUDCheckboxButton(
            frame: NSRect(x: x, y: midY - 10,
                          width: Self.checkboxWidth(title: calloutLabel), height: 20),
            title: calloutLabel, target: self, action: #selector(calloutToggled(_:))
        )
        calloutCheckbox.state = calloutEnabled ? .on : .off
        addSubview(calloutCheckbox)
    }

    private static func checkboxWidth(title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return 16 + 8 + textWidth
    }

    @objc private func fontSizeChanged(_ sender: HUDSlider) {
        let raw = CGFloat(sender.doubleValue)
        let clamped = max(fontSizeMin, min(fontSizeMax, raw))
        onFontSizeChanged?(clamped)
    }

    @objc private func colorTapped(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view as? ColorSwatchView else { return }
        let index = view.itemIndex
        guard index < colors.count else { return }
        let color = colors[index]
        for (i, v) in colorButtons.enumerated() where i < colors.count {
            v.isSelected = colorsMatch(colors[i], color)
        }
        onColorChanged?(color)
    }

    @objc private func strokeToggled(_ sender: HUDCheckboxButton) {
        onStrokeChanged?(sender.state == .on)
    }

    @objc private func calloutToggled(_ sender: HUDCheckboxButton) {
        onCalloutChanged?(sender.state == .on)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSubToolbarBackground(dirtyRect, in: self)
    }
}

// MARK: - MosaicSubToolbar

/// 马赛克块大小子工具栏。参照 capcap `MosaicSubToolbar`。
final class MosaicSubToolbar: NSView {
    var onBlockSizeBegan: (() -> Void)?
    var onBlockSizeChanged: ((CGFloat) -> Void)?
    var onBlockSizeEnded: (() -> Void)?

    private let blockSizeMin: CGFloat
    private let blockSizeMax: CGFloat

    static let preferredWidth: CGFloat = 178
    private static let sliderWidth: CGFloat = 154

    init(frame: NSRect,
         currentBlockSize: CGFloat,
         blockSizeMin: CGFloat = EditorStyleDefaults.mosaicBlockSizeMin,
         blockSizeMax: CGFloat = EditorStyleDefaults.mosaicBlockSizeMax) {
        self.blockSizeMin = blockSizeMin
        self.blockSizeMax = max(blockSizeMin, blockSizeMax)
        super.init(frame: frame)
        setup(currentBlockSize: min(max(currentBlockSize, self.blockSizeMin), self.blockSizeMax))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup(currentBlockSize: CGFloat) {
        let x: CGFloat = 12
        let midY = bounds.midY
        let slider = HUDSlider(frame: NSRect(
            x: x, y: midY - HUDSlider.preferredHeight / 2,
            width: MosaicSubToolbar.sliderWidth, height: HUDSlider.preferredHeight
        ))
        slider.minValue = Double(blockSizeMin)
        slider.maxValue = Double(blockSizeMax)
        slider.doubleValue = Double(currentBlockSize)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(blockSizeChanged(_:))
        slider.onEditingBegan = { [weak self] in self?.onBlockSizeBegan?() }
        slider.onEditingEnded = { [weak self] in self?.onBlockSizeEnded?() }
        slider.toolTip = "Mosaic Granularity"
        addSubview(slider)
    }

    @objc private func blockSizeChanged(_ sender: HUDSlider) {
        let value = min(max(CGFloat(sender.doubleValue), blockSizeMin), blockSizeMax)
        onBlockSizeChanged?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSubToolbarBackground(dirtyRect, in: self)
    }
}
