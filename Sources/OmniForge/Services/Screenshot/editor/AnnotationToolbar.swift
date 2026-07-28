import AppKit

// MARK: - HUD 视觉常量

/// 编辑器浮动 HUD 的视觉常量。参照 capcap `EditWindowController`：
/// 圆角8、阴影 opacity0.25/radius10/offset(0,-2)、强调绿、危险红。
enum EditorHUD {
    static let cornerRadius: CGFloat = 8
    static let shadowOpacity: Float = 0.25
    static let shadowRadius: CGFloat = 10
    static let shadowOffset = CGSize(width: 0, height: -2)

    /// 选中态强调色（与 SelectionView 一致）。
    static let accentGreen = NSColor(red: 0, green: 212.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)
    /// 关闭按钮的危险红。
    static let dangerRed = NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)

    /// 工具栏圆角胶囊背景（自画，跟随明暗）。
    static func toolbarBackground() -> NSColor {
        isDark ? NSColor(white: 0.12, alpha: 0.90) : NSColor(white: 0.97, alpha: 0.94)
    }

    /// 选中按钮的浅底。
    static func selectedFill() -> NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.10)
    }

    /// 1px 分隔线。
    static func separator() -> NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.20) : NSColor.black.withAlphaComponent(0.16)
    }

    private static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - 工具栏项

/// 工具栏按钮的稳定标识。参照 capcap `ToolbarItemID`。
enum AnnotationToolbarItem: String, CaseIterable {
    // 标注工具（切换 EditTool）
    case rectangle, ellipse, line, arrow, pen, marker
    case mosaic, eraser, magnifier, number, text, emoji, image
    // 选区手势 / 状态动作
    case moveSelection
    case scrollCapture
    case record
    case colorPicker, undo, redo
    // 布局占位（无按钮）
    case separator
    // 输出动作
    case save, pin, close, confirm

    enum Kind {
        case toggleTool   // 切换一个 EditTool，带选中态
        case momentary    // 单次触发，无选中态
        case dragHandle   // 按住拖动（非 toggle）
        case stickyAction // 可保持 active 高亮（长截图等）
        case layoutOnly   // 仅占位/绘制，不创建按钮
    }

    var kind: Kind {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .pen, .marker,
             .mosaic, .eraser, .magnifier, .number, .text, .emoji:
            return .toggleTool
        case .moveSelection:
            return .dragHandle
        case .scrollCapture:
            return .stickyAction
        case .separator:
            return .layoutOnly
        case .image, .record, .colorPicker, .undo, .redo, .save, .pin, .close, .confirm:
            return .momentary
        }
    }

    /// toggleTool 项映射到的 EditTool。
    var editTool: EditTool? {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse:   return .ellipse
        case .line:      return .line
        case .arrow:     return .arrow
        case .pen:       return .pen
        case .marker:    return .marker
        case .mosaic:    return .mosaic
        case .eraser:    return .eraser
        case .magnifier: return .magnifier
        case .number:    return .number
        case .text:      return .text
        case .emoji:     return .emoji
        default:         return nil
        }
    }

    /// SF Symbol 名称。参照 capcap `ToolbarLayout.symbolName`。
    var symbolName: String {
        switch self {
        case .rectangle:  return "rectangle"
        case .ellipse:    return "circle"
        case .arrow:      return "arrow.up.right"
        case .line:       return "line.diagonal"
        case .pen:        return "pencil.tip"
        case .marker:     return "highlighter"
        case .mosaic:     return "square.grid.3x3"
        case .eraser:     return "eraser"
        case .magnifier:  return "plus.magnifyingglass"
        case .number:     return "1.circle"
        case .text:       return "textformat"
        case .emoji:      return "face.smiling"
        case .image:      return "photo"
        case .moveSelection: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scrollCapture: return "arrow.up.and.down.text.horizontal"
        case .record: return "record.circle"
        case .colorPicker: return "eyedropper"
        case .undo:       return "arrow.uturn.backward"
        case .redo:       return "arrow.uturn.forward"
        case .separator:  return ""
        case .save:       return "square.and.arrow.down"
        case .pin:        return "pin"
        case .close:      return "xmark"
        case .confirm:    return "checkmark"
        }
    }

    /// 悬停提示文案。消费已有的 Strings key（annotationTool*/annotationAction*），
    /// 缺失的（eraser/magnifier/emoji/image/undo/redo/close/confirm/colorPicker）
    /// 用英文字面量兜底——这些仅作 tooltip 展示。
    func tooltip(strings: Strings) -> String {
        let title: String
        switch self {
        case .rectangle:  title = strings.annotationToolRectangle
        case .ellipse:    title = strings.annotationToolEllipse
        case .arrow:      title = strings.annotationToolArrow
        case .line:       title = strings.annotationToolLine
        case .pen:        title = strings.annotationToolFreehand
        case .marker:     title = strings.annotationToolHighlighter
        case .mosaic:     title = strings.annotationToolMosaic
        case .eraser:     title = "Eraser"
        case .magnifier:  title = "Magnifier"
        case .number:     title = strings.annotationToolCounter
        case .text:       title = strings.annotationToolText
        case .emoji:      title = "Emoji"
        case .image:      title = "Insert Image"
        case .moveSelection: title = strings.tipMoveSelection
        case .scrollCapture: title = strings.tipScrollCapture
        case .record: title = strings.tipRecord
        case .colorPicker: title = "Color Picker"
        case .undo:       title = "Undo"
        case .redo:       title = "Redo"
        case .separator:  return ""
        case .save:       title = strings.annotationActionSave
        case .pin:        title = strings.annotationActionPin
        case .close:      title = "Close"
        case .confirm:    title = strings.annotationActionCopy
        }
        guard let shortcut = shortcutDisplay else { return title }
        return "\(title) (\(shortcut))"
    }

    /// 快捷键展示（参照 capcap `editorShortcutDisplay`）。
    var shortcutDisplay: String? {
        switch self {
        case .rectangle: return "R"
        case .ellipse:   return "O"
        case .line:      return "L"
        case .arrow:     return "A"
        case .pen:       return "D"
        case .marker:    return "H"
        case .mosaic:    return "M"
        case .eraser:    return "E"
        case .text:      return "T"
        case .number:    return "N"
        case .pin:       return "P"
        case .save:      return "⌘S"
        case .confirm:   return "⏎"
        case .undo:      return "⌘Z"
        case .redo:      return "⇧⌘Z"
        case .close:     return "X"
        default:         return nil
        }
    }

    /// 单字母快捷键（用于控制器的本地键盘监听匹配）。参照 capcap
    /// `EditorKeyboardShortcut`。
    var singleLetterShortcut: String? {
        switch self {
        case .rectangle: return "r"
        case .ellipse:   return "o"
        case .line:      return "l"
        case .arrow:     return "a"
        case .pen:       return "d"
        case .marker:    return "h"
        case .mosaic:    return "m"
        case .eraser:    return "e"
        case .text:      return "t"
        case .number:    return "n"
        case .pin:       return "p"
        case .close:     return "x"
        default:         return nil
        }
    }

    /// 静止态图标色。
    var normalColor: NSColor {
        switch self {
        case .close:   return EditorHUD.dangerRed
        case .confirm: return EditorHUD.accentGreen
        default:       return .labelColor
        }
    }

    /// 选中态图标色。momentary / dragHandle 项不进入选中态。
    var selectedColor: NSColor {
        switch kind {
        case .toggleTool, .stickyAction: return EditorHUD.accentGreen
        case .momentary, .dragHandle, .layoutOnly: return normalColor
        }
    }
}

// MARK: - 工具栏布局

/// 单行水平工具栏项集：标注工具 → 手势/状态 → 历史 → 分隔 → 输出动作。
/// 参照 capcap 能力子集，去掉 ocr/upload/beautify/qrCode 与插入图片入口。
enum AnnotationToolbarLayout {
    static let primary: [AnnotationToolbarItem] = [
        .rectangle, .ellipse, .line, .arrow, .pen, .marker,
        .mosaic, .eraser, .number, .text, .emoji,
        .colorPicker, .magnifier, .moveSelection, .scrollCapture, .record, .undo, .redo,
        .separator,
        .save, .pin, .close, .confirm,
    ]
}

// MARK: - ToolButton

/// 工具栏按钮：无边框、SF Symbol 14pt medium、选中绿底圆角6。
/// 参照 capcap `ToolButton`（L2879-2964）。
final class AnnotationToolButton: NSButton {
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    /// 悬停提示文案。nil 表示无提示。
    var hoverTip: String?

    private let normalColor: NSColor
    private let selectedColor: NSColor
    private var hoverTrackingArea: NSTrackingArea?

    init(frame: NSRect, symbolName: String, normalColor: NSColor, selectedColor: NSColor) {
        self.normalColor = normalColor
        self.selectedColor = selectedColor
        super.init(frame: frame)

        bezelStyle = .regularSquare
        isBordered = false
        setButtonType(.momentaryPushIn)

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            image = img.withSymbolConfiguration(config)
        }
        contentTintColor = normalColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let tip = hoverTip else { return }
        toolTip = tip
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            contentTintColor = selectedColor
            let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            EditorHUD.selectedFill().setFill()
            bgPath.fill()
        } else {
            contentTintColor = normalColor
        }
        super.draw(dirtyRect)
    }
}

// MARK: - ToolbarView

/// 工具栏视图：自画圆角8 HUD 背景。支持水平/竖直两种朝向。
/// 参照 capcap `ToolbarView`（L2681-2875）：按钮 32pt、间距6、端距15、
/// 胶囊厚44（32 + 6*2）；分隔线占位 13pt（6+1+6）。
final class AnnotationToolbarView: NSView {
    enum Orientation { case horizontal, vertical }

    /// 按钮几何（参照 capcap 静态常量）。
    static let buttonSize: CGFloat = 32
    static let buttonSpacing: CGFloat = 6
    static let endPadding: CGFloat = 15
    static let crossPadding: CGFloat = 6
    /// 分隔线厚度。
    static let separatorThickness: CGFloat = 1
    /// 分隔线两侧内边距（合计占位 = padding*2 + thickness）。
    static let separatorPadding: CGFloat = 6

    let orientation: Orientation
    private let items: [AnnotationToolbarItem]
    private let stringsProvider: () -> Strings

    /// 当前按钮集合在当前朝向下的最佳尺寸。
    var preferredSize: NSSize {
        let run = contentRunLength + Self.endPadding * 2
        let thickness = Self.buttonSize + Self.crossPadding * 2
        switch orientation {
        case .horizontal: return NSSize(width: max(run, thickness), height: thickness)
        case .vertical:   return NSSize(width: thickness, height: max(run, thickness))
        }
    }

    // MARK: 回调（控制器注入）
    var onToolSelected: ((EditTool) -> Void)?
    var onColorPicker: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onMoveSelectionStart: (() -> Void)?
    var onMoveSelectionDrag: ((CGSize) -> Void)?
    var onMoveSelectionEnd: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onRecord: (() -> Void)?

    private var buttons: [AnnotationToolbarItem: AnnotationToolButton] = [:]
    private var moveSelectionHandle: MoveSelectionDragHandle?
    private var separatorFrames: [NSRect] = []
    /// 当前选中工具。再次点击同一工具回退到 `.none`（调整模式）。
    private var currentTool: EditTool = .none
    private var isScrollCaptureActive = false

    init(items: [AnnotationToolbarItem],
         orientation: Orientation,
         stringsProvider: @escaping () -> Strings = { .en }) {
        self.items = items
        self.orientation = orientation
        self.stringsProvider = stringsProvider
        super.init(frame: NSRect(origin: .zero, size: .zero))
        setFrameSize(preferredSize)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 选中/可用性

    /// 更新工具选中态。
    func updateSelection(tool: EditTool) {
        currentTool = tool
        for (id, btn) in buttons where id.kind == .toggleTool {
            btn.isSelected = (id.editTool == tool)
        }
    }

    /// 启用/禁用某项并变暗。
    func setEnabled(_ enabled: Bool, for id: AnnotationToolbarItem) {
        guard let btn = buttons[id] else { return }
        btn.isEnabled = enabled
        btn.alphaValue = enabled ? 1.0 : 0.35
    }

    func setUndoEnabled(_ enabled: Bool) { setEnabled(enabled, for: .undo) }
    func setRedoEnabled(_ enabled: Bool) { setEnabled(enabled, for: .redo) }

    func setScrollCaptureEnabled(_ enabled: Bool) {
        setEnabled(enabled, for: .scrollCapture)
    }

    func setScrollCaptureActive(_ active: Bool) {
        isScrollCaptureActive = active
        buttons[.scrollCapture]?.isSelected = active
    }

    /// 某项的按钮 frame（工具栏自身坐标系）。
    func frame(for id: AnnotationToolbarItem) -> NSRect? {
        if id == .moveSelection { return moveSelectionHandle?.frame }
        if id.kind == .layoutOnly { return nil }
        return buttons[id]?.frame
    }

    /// 长截图按钮 frame（工具栏坐标系），供 stop chrome 锚定。
    var scrollCaptureButtonFrame: NSRect? { frame(for: .scrollCapture) }

    func contains(_ id: AnnotationToolbarItem) -> Bool {
        if id == .moveSelection { return moveSelectionHandle != nil }
        if id.kind == .layoutOnly { return false }
        return buttons[id] != nil
    }

    // MARK: 布局

    private static func runLength(for id: AnnotationToolbarItem) -> CGFloat {
        switch id.kind {
        case .layoutOnly:
            return separatorPadding * 2 + separatorThickness
        case .toggleTool, .momentary, .dragHandle, .stickyAction:
            return buttonSize
        }
    }

    private var contentRunLength: CGFloat {
        guard !items.isEmpty else { return 0 }
        let itemRun = items.reduce(CGFloat(0)) { $0 + Self.runLength(for: $1) }
        let gaps = CGFloat(max(0, items.count - 1)) * Self.buttonSpacing
        return itemRun + gaps
    }

    private func setupButtons() {
        let size = Self.buttonSize
        separatorFrames.removeAll(keepingCapacity: true)
        var along = Self.endPadding
        for (index, id) in items.enumerated() {
            let run = Self.runLength(for: id)
            let frame: NSRect
            switch orientation {
            case .horizontal:
                frame = NSRect(x: along, y: Self.crossPadding, width: run, height: size)
            case .vertical:
                // AppKit y 向上增长，首项置顶。
                let y = bounds.height - along - run
                frame = NSRect(x: Self.crossPadding, y: y, width: size, height: run)
            }
            along += run + Self.buttonSpacing

            if id.kind == .layoutOnly {
                separatorFrames.append(frame)
                continue
            }
            if id == .moveSelection {
                let handleFrame = NSRect(x: frame.minX, y: frame.minY, width: size, height: size)
                let handle = MoveSelectionDragHandle(frame: handleFrame, symbolName: id.symbolName)
                handle.toolTip = id.tooltip(strings: stringsProvider())
                handle.onDragStart = { [weak self] in self?.onMoveSelectionStart?() }
                handle.onDrag = { [weak self] delta in self?.onMoveSelectionDrag?(delta) }
                handle.onDragEnd = { [weak self] in self?.onMoveSelectionEnd?() }
                moveSelectionHandle = handle
                addSubview(handle)
                continue
            }
            let btnFrame = NSRect(x: frame.minX, y: frame.minY, width: size, height: size)
            let btn = AnnotationToolButton(
                frame: btnFrame,
                symbolName: id.symbolName,
                normalColor: id.normalColor,
                selectedColor: id.selectedColor
            )
            btn.hoverTip = id.tooltip(strings: stringsProvider())
            btn.toolTip = id.tooltip(strings: stringsProvider())
            btn.target = self
            btn.action = #selector(buttonTapped(_:))
            btn.tag = index
            buttons[id] = btn
            addSubview(btn)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                xRadius: EditorHUD.cornerRadius,
                                yRadius: EditorHUD.cornerRadius)
        EditorHUD.toolbarBackground().setFill()
        path.fill()

        // 工具区与动作区之间的 1px 分隔线。
        EditorHUD.separator().setFill()
        for slot in separatorFrames {
            switch orientation {
            case .horizontal:
                let x = slot.midX - Self.separatorThickness / 2
                let y = slot.minY + 4
                let h = max(0, slot.height - 8)
                NSRect(x: x, y: y, width: Self.separatorThickness, height: h).fill()
            case .vertical:
                let y = slot.midY - Self.separatorThickness / 2
                let x = slot.minX + 4
                let w = max(0, slot.width - 8)
                NSRect(x: x, y: y, width: w, height: Self.separatorThickness).fill()
            }
        }
    }

    @objc private func buttonTapped(_ sender: AnnotationToolButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        let id = items[sender.tag]
        switch id {
        case .rectangle, .ellipse, .line, .arrow, .pen, .marker,
             .mosaic, .eraser, .magnifier, .number, .text, .emoji:
            guard let tool = id.editTool else { return }
            // 点击已选中工具回退到 .none（调整模式）。
            onToolSelected?(tool == currentTool ? .none : tool)
        case .moveSelection, .separator, .image:
            // 拖动手柄走 mouseDown/Dragged/Up；separator/image 无工具栏入口。
            break
        case .scrollCapture: onScrollCapture?()
        case .record:      onRecord?()
        case .colorPicker: onColorPicker?()
        case .undo:        onUndo?()
        case .redo:        onRedo?()
        case .save:        onSave?()
        case .pin:         onPin?()
        case .close:       onClose?()
        case .confirm:     onConfirm?()
        }
    }
}

// MARK: - MoveSelectionDragHandle

/// 工具栏「移动选区」拖动手柄：按下记起点，拖动上报 delta，抬起结束。
/// 对齐 CapCap：空白拖动不移动选区，仅此手柄驱动 external move；
/// 图标自绘（无子视图），悬停 openHand、按下/拖动 closedHand。
final class MoveSelectionDragHandle: NSView {
    var onDragStart: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnd: (() -> Void)?

    private let symbolName: String
    private var dragStartLocation: NSPoint = .zero
    private var isDragging = false {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = convert(event.locationInWindow, from: nil)
        isDragging = true
        NSCursor.closedHand.set()
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        NSCursor.closedHand.set()
        let current = convert(event.locationInWindow, from: nil)
        let delta = CGSize(
            width: current.x - dragStartLocation.x,
            height: current.y - dragStartLocation.y
        )
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.openHand.set()
        onDragEnd?()
        dragStartLocation = .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isDragging {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            EditorHUD.selectedFill().setFill()
            bg.fill()
        }

        guard let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)) else { return }
        // 用 sourceAtop 把模板图标染成 labelColor，对齐 CapCap 自绘着色。
        let tint = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let drawRect = NSRect(
            x: bounds.midX - tint.size.width / 2,
            y: bounds.midY - tint.size.height / 2,
            width: tint.size.width,
            height: tint.size.height
        )
        tint.draw(in: drawRect)
    }
}
