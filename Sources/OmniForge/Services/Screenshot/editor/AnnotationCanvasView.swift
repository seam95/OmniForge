import AppKit
import Foundation

/// 编辑器工具枚举。
///
/// 顶层声明（原位于 `AnnotationEditorController`），画布与控制器共用。
/// `none` 表示「调整模式」——点击仅做选中/拖拽，不创建新标注。
enum EditTool: String, CaseIterable, Equatable, Sendable {
    case none
    case pen
    case marker
    case rectangle
    case ellipse
    case arrow
    case line
    case text
    case mosaic
    case number
    case magnifier
    case emoji
    case image
    case eraser
}

/// 标注画布视图——画布交互层的核心。
///
/// 完全参照 capcap `EditCanvasView`（`Editor/EditCanvasView.swift`）重写：
/// - 绘制底图 + 全部标注 + 选中 chrome（虚线框、resize/rotate/curve/tip/
///   magnifierSource/arrow handle、delete/edit/步进按钮、hover 高亮）。
/// - 鼠标交互：action 按钮 → 橡皮擦 → 选择 handle → 标注 body → 空白建工具。
/// - handle 拖拽（rotate/resize/curve/tip/textCalloutTip/magnifierSource/
///   arrowStart/arrowEnd）、body 平移、各工具实时预览与提交。
/// - undo/redo 委托给 `AnnotationDocument`（三段式 pending 机制）。
/// - 文字编辑生命周期（`beginTextEditing`/`handleTextCommit`/`handleTextCancel`/
///   `reEditTextAnnotation`），延后一拍创建浮层避免 responder 抖动。
/// - Shift 约束（正方形/正圆/水平垂直线/15° 旋转吸附）。
/// - cursor 切换 + trackingArea hover 高亮。
///
/// 注：OmniForge 标注 API 与 capcap 不同——Line/Arrow 用 `start`/`end`、
/// Pen/Marker 用 `[CGPoint]`、document 持有 undo 栈，已逐一适配。
class AnnotationCanvasView: NSView {
    weak var controller: AnnotationEditorController?

    /// 标注文档引用（从控制器注入）。文档持有标注栈 + undo/redo。
    var document: AnnotationDocument?

    /// 底图。
    var baseImage: NSImage? {
        didSet { needsDisplay = true }
    }

    /// 当前捕获矩形（CG 全局坐标）；选区变更时由控制器同步。
    var captureRect: CGRect?
    /// 预抓整屏快照；重裁切底图时使用。
    var preSnapshot: CGImage?
    /// 源屏 displayID。
    var sourceDisplayID: CGDirectDisplayID?
    /// 源屏引用：现裁底图时由控制器同步（对齐 CapCap `captureScreen`）。
    var captureScreen: NSScreen?

    /// 长截图裁剪确认后的预览底图（优先于 `baseImage`）。
    private(set) var previewImage: NSImage?

    /// 长截图预览图是否存在（供 interaction state / hitTest / composite 使用）。
    var hasPreviewImage: Bool { previewImage != nil }

    /// 加载长截图预览：取消进行中的绘制交互，替换预览底图并调整画布尺寸。
    func loadPreviewImage(_ image: NSImage) {
        cancelInFlightInteraction()
        previewImage = image
        setFrameSize(image.size)
        needsDisplay = true
    }

    /// 取消进行中的拖拽/绘制/文字编辑，避免预览切换时残留状态。
    private func cancelInFlightInteraction() {
        commitActiveTextEditing()
        if dragState != nil {
            dragState = nil
            document?.discardPendingUndo()
        }
        if eraserSelection != nil {
            if eraserSelection?.didDelete != true {
                document?.discardPendingUndo()
            }
            eraserSelection = nil
        }
        emojiPreviewPoint = nil
        shapeRoughSeed = nil
        selectedIndexes = []
        primarySelectedIndex = nil
        needsDisplay = true
    }

    /// 当前活动工具。didSet 处理工具切换副作用（提交文字、收起橡皮擦/
    /// emoji 预览、清选区、刷新光标）。参照 capcap L31-55。
    var activeTool: EditTool = .none {
        didSet {
            if oldValue == .text, activeTool != .text {
                activeTextField?.commit()
            }
            if oldValue == .eraser, activeTool != .eraser {
                if eraserSelection?.didDelete != true {
                    document?.discardPendingUndo()
                }
                eraserSelection = nil
            }
            if activeTool == .eraser {
                primarySelectedIndex = nil
                selectedIndexes = []
            }
            if activeTool != .emoji {
                emojiPreviewPoint = nil
            }
            if activeTool != .rectangle && activeTool != .ellipse {
                shapeRoughSeed = nil
            }
            refreshCursorAtCurrentLocation()
        }
    }

    // MARK: - 绘图样式槽位（由工具栏设置）

    /// 当前颜色（画笔/形状/箭头/编号/放大镜描边/普通文字）。
    var currentColor: NSColor = .red {
        didSet { activeTextField?.annotationColor = currentColor }
    }
    /// 新文字标注是否带对比描边。
    var currentTextStroke: Bool = false {
        didSet { activeTextField?.hasStroke = currentTextStroke }
    }
    /// 新文字标注是否渲染为气泡（带可拖箭头尾）。
    var currentTextCallout: Bool = false {
        didSet { activeTextField?.hasCallout = currentTextCallout }
    }
    /// 矩形/椭圆填充模式。
    var currentShapeFillMode: ShapeFillMode = .none
    /// 矩形/椭圆描边样式。
    var currentShapeStrokeStyle: ShapeStrokeStyle = .standard
    /// 画笔/形状/箭头/线/放大镜描边宽度。
    var currentLineWidth: CGFloat = 3
    /// 箭头样式。
    var currentArrowStyle: ArrowStyle = .tapered
    /// 荧光笔基础宽度（绘制时 × brushScale）。
    var currentMarkerLineWidth: CGFloat = 5
    /// 荧光笔独立颜色槽（切换工具时保留各自颜色）。
    var currentMarkerColor: NSColor = .yellow
    /// 马赛克块大小。
    var currentMosaicBlockSize: CGFloat = 12
    /// 文字字号。
    var currentFontSize: CGFloat = 18 {
        didSet {
            guard let field = activeTextField else { return }
            field.font = NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
            field.sizeToFitText()
        }
    }
    /// emoji 工具待盖印的 emoji。
    var currentEmoji: String? {
        didSet {
            if activeTool == .emoji {
                needsDisplay = true
            }
        }
    }

    // MARK: - 回调闭包

    /// 选中标注身份变化时触发（单选传标注，否则 nil）。
    var onAnnotationSelected: ((Annotation?) -> Void)?
    /// 多选模式进入/退出时触发。
    var onMultiSelectionChanged: ((Bool) -> Void)?
    /// undo/redo 可用性变化时触发，参数 (canUndo, canRedo)。
    var onHistoryStateChanged: ((Bool, Bool) -> Void)?
    /// emoji 盖印后触发，控制器据此清待定 emoji。
    var onEmojiStamped: (() -> Void)?

    // MARK: - 内部状态

    /// 自由绘制点序列（pen/marker）。
    private var currentPenPoints: [NSPoint]?
    private var currentMarkerPoints: [NSPoint]?
    /// 形状起点/当前点（rect/ellipse/arrow/line/mosaic/magnifier）。
    private var shapeStart: NSPoint?
    private var shapeCurrent: NSPoint?
    /// 手绘粗糙度种子，同一拖拽内稳定（Shift 约束重绘时保持形状）。
    private var shapeRoughSeed: UInt64?
    /// 放大镜拖拽开始时缓存底图，预览与提交共用一次解析。
    private var magnifierBaseImage: NSImage?
    /// 活动文字编辑浮层。
    private var activeTextField: EditableTextField?
    /// 编辑现有文字时，原标注从栈中暂移除存此；commit 丢弃，cancel 回插。
    private var editingOriginalAnnotation: TextAnnotation?
    private var editingOriginalIndex: Int?
    /// 标注 body 拖拽状态。
    private var dragState: DragState?
    /// handle 拖拽状态（rotate/resize/curve/tip/...）。
    private var handleDragState: HandleDragState?
    /// 待定编号创建（点击点为徽章中心，拖拽拉出箭头尖）。
    private var pendingNumberCreate: PendingNumberCreate?
    /// 待定文字创建（点击点为文字底左，拖拽拉出气泡箭头尖）。
    private var pendingTextCreate: PendingTextCreate?
    /// emoji 预览点。
    private var emojiPreviewPoint: NSPoint?
    /// hover 高亮的标注索引。
    private var hoveredAnnotationIndex: Int?
    /// 橡皮擦框选矩形。
    private var eraserSelection: EraserSelection?
    /// body 拖拽触发的位移阈值（pt），过滤纯点击。
    private let dragThreshold: CGFloat = 4
    /// 多选索引集合 + 主选索引。
    private var selectedIndexes: Set<Int> = []
    private var primarySelectedIndex: Int?
    private var hasSelection: Bool { !selectedIndexes.isEmpty }
    /// 当前合法的选中索引（过滤越界）。
    private var validSelectedIndexes: [Int] {
        let count = document?.annotations.count ?? 0
        return selectedIndexes.filter { (0..<count).contains($0) }.sorted()
    }
    private var trackingArea: NSTrackingArea?
    /// 子工具栏拖拽调整（颜色/字号滑块）时的脏标志。
    private var selectionAdjustmentDirty = false

    // MARK: - chrome 常量（参照 capcap L328-342）

    private static let rotateHandleSize: CGFloat = 22
    private static let rotateHandleOffset: CGFloat = 22
    private static let curveHandleSize: CGFloat = 14
    private static let tipHandleSize: CGFloat = 14
    private static let textCalloutHandleSize: CGFloat = 13
    private static let magnifierSourceHandleSize: CGFloat = 14
    private static let endpointHandleSize: CGFloat = 12
    private static let resizeHandleSize: CGFloat = 10
    private static let actionButtonSize: CGFloat = 22
    private static let numberStepButtonSize: CGFloat = 20
    private static let selectionBoxPad: CGFloat = 6
    private static let hoverBoxPad: CGFloat = 5
    private static let hoverColor = NSColor(calibratedRed: 0.0, green: 0.56, blue: 1.0, alpha: 1.0)
    private static let selectionOutlineColor = NSColor(calibratedWhite: 0.36, alpha: 0.9)
    private static let accentGreen = NSColor(calibratedRed: 0.0, green: 212.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)
    private static let fallbackShapePreviewSeed: UInt64 = 0xC0DEC0DEC0DEC0DE
    private static let defaultPasteOffset = NSPoint(x: 12, y: -12)
    private static var annotationPasteboard: [Annotation] = []

    /// 选中主索引的便捷读写（单选路径用）。
    private var selectedIndex: Int? {
        get { primarySelectedIndex }
        set {
            if let newValue {
                setSelectedIndexes([newValue], primary: newValue)
            } else {
                setSelectedIndexes([], primary: nil)
            }
        }
    }

    /// 当前选中的单个标注（控制器读它来种子子工具栏）。
    var selectedAnnotation: Annotation? {
        guard selectedIndexes.count == 1,
              let idx = selectedIndex,
              let count = document?.annotations.count,
              idx < count else { return nil }
        return document?.annotations[idx].annotation
    }

    /// 是否正在编辑文字（控制器据此让出快捷键）。
    var isEditingText: Bool { activeTextField != nil }

    /// 清多选。返回是否真的清了（用于控制器收起子工具栏）。
    @discardableResult
    func clearMultiSelection() -> Bool {
        guard selectedIndexes.count > 1 else { return false }
        selectedIndex = nil
        return true
    }

    // MARK: - 拖拽状态结构

    private struct DragState {
        let index: Int
        let startMouse: NSPoint
        let originals: [Int: Annotation]
        var didDrag: Bool
    }

    private struct PendingNumberCreate {
        let start: NSPoint
        var current: NSPoint
    }

    private struct PendingTextCreate {
        let start: NSPoint
        var current: NSPoint
        let wasEditing: Bool
    }

    private struct EraserSelection {
        let start: NSPoint
        var current: NSPoint
        var didDelete: Bool
    }

    /// 八方向 resize 锚点（坐标 y-up）。参照 capcap L286-300。
    enum ResizeAnchor: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var movesMaxY: Bool { self == .topLeft || self == .top || self == .topRight }

        func point(in rect: NSRect) -> NSPoint {
            let x: CGFloat = movesMinX ? rect.minX : (movesMaxX ? rect.maxX : rect.midX)
            let y: CGFloat = movesMinY ? rect.minY : (movesMaxY ? rect.maxY : rect.midY)
            return NSPoint(x: x, y: y)
        }
    }

    private enum ResizeConstraint {
        case none, preserveAspectRatio, square
    }

    /// handle 拖拽种类。
    private struct HandleDragState {
        enum Kind {
            case rotate, curve, tip, textCalloutTip, magnifierSource, arrowStart, arrowEnd
            case resize(ResizeAnchor)
        }
        let kind: Kind
        let index: Int
        let original: Annotation
        let startMouse: NSPoint
        let startAngle: CGFloat
        let startRotation: CGFloat
    }

    // MARK: - 初始化

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 工具激活、长截图预览或绘制中时画布总是接管点击。
        if activeTool != .none || hasPreviewImage {
            return super.hitTest(point)
        }
        let local = convert(point, from: superview)
        if hitTestAnnotation(at: local) != nil { return super.hitTest(point) }
        if hitTestSelectionHandle(at: local) != nil { return super.hitTest(point) }
        if hitTestSelectionAction(at: local) != nil { return super.hitTest(point) }
        // 无工具时空白一律透传给下方 SelectionView，让选区内按住即可拖动选区。
        // 此前曾用 `hasSelection || activeTextField != nil` 捕获空白以清除选中 chrome，
        // 但那会吞掉 mouseDown，导致选区拖不动；选中清除改由工具切换/选区变更时处理。
        return nil
    }

    // MARK: - 选中管理

    private func notifySelectionChanged() {
        guard let cb = onAnnotationSelected else { return }
        let count = document?.annotations.count ?? 0
        if selectedIndexes.count == 1, let idx = selectedIndex, idx < count {
            cb(document?.annotations[idx].annotation)
        } else {
            cb(nil)
        }
    }

    private func setSelectedIndexes(_ indexes: Set<Int>, primary: Int? = nil) {
        let total = document?.annotations.count ?? 0
        let wasMultiSelecting = selectedIndexes.count > 1
        let validIndexes = Set(indexes.filter { (0..<total).contains($0) })
        let resolvedPrimary: Int?
        if let primary, validIndexes.contains(primary) {
            resolvedPrimary = primary
        } else if let current = primarySelectedIndex, validIndexes.contains(current) {
            resolvedPrimary = current
        } else {
            resolvedPrimary = validIndexes.max()
        }

        let changed = validIndexes != selectedIndexes || resolvedPrimary != primarySelectedIndex
        selectedIndexes = validIndexes
        primarySelectedIndex = resolvedPrimary
        if changed {
            needsDisplay = true
            let isMultiSelecting = validIndexes.count > 1
            if wasMultiSelecting != isMultiSelecting {
                onMultiSelectionChanged?(isMultiSelecting)
            }
            notifySelectionChanged()
        }
    }

    private func toggleSelection(of index: Int) {
        var next = selectedIndexes
        if next.contains(index) {
            next.remove(index)
            setSelectedIndexes(next)
        } else {
            next.insert(index)
            setSelectedIndexes(next, primary: index)
        }
    }

    // MARK: - 文档/底图解析

    /// 编辑用底图。优先级（对齐 CapCap `resolveBaseImageForEditing`）：
    /// 1. 长截图 `previewImage`
    /// 2. `preSnapshot` + 当前 `captureRect` 现裁（普通编辑态主路径）
    /// 3. 注入的 `baseImage`（fallback：preSnapshot 缺失时）
    func resolveBaseImageForEditing() -> NSImage? {
        if let previewImage { return previewImage }
        if let snap = preSnapshot,
           let rect = captureRect,
           let displayID = sourceDisplayID,
           let cropped = snap.croppingToSelection(globalRect: rect, displayID: displayID) {
            // croppingToSelection 返回物理像素 CGImage；size 用视图尺寸归一化，draw 时不被二次缩放。
            let viewSize = bounds.size.width > 0 && bounds.size.height > 0
                ? bounds.size
                : CGSize(width: cropped.width, height: cropped.height)
            return NSImage(cgImage: cropped, size: viewSize)
        }
        return baseImage
    }

    private func annotation(at index: Int) -> Annotation? {
        guard let doc = document, doc.annotations.indices.contains(index) else { return nil }
        return doc.annotations[index].annotation
    }

    // MARK: - 鼠标事件

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredAnnotationIndex(nil)
        let isShiftSelecting = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)

        // 1. action 按钮（delete/edit/步进）命中 → 直接执行。参照 capcap L953-988。
        if !isShiftSelecting,
           let action = hitTestSelectionAction(at: point),
           let idx = selectedIndex {
            activeTextField?.commit()
            switch action {
            case .delete:
                deleteSelectedAnnotation()
            case .edit:
                if let textAnnotation = annotation(at: idx) as? TextAnnotation {
                    reEditTextAnnotation(at: idx, annotation: textAnnotation)
                }
            case .incrementNumber:
                mutateSelectedAnnotationAtomic { annotation in
                    guard let n = annotation as? NumberAnnotation else { return annotation }
                    return n.withNumber(n.number + 1)
                }
            case .decrementNumber:
                mutateSelectedAnnotationAtomic { annotation in
                    guard let n = annotation as? NumberAnnotation else { return annotation }
                    return n.withNumber(max(1, n.number - 1))
                }
            case .zoomInMagnifier:
                mutateSelectedAnnotationAtomic { annotation in
                    guard let magnifier = annotation as? MagnifierAnnotation else { return annotation }
                    return magnifier.withZoom(magnifier.zoom + MagnifierAnnotation.zoomStep)
                }
            case .zoomOutMagnifier:
                mutateSelectedAnnotationAtomic { annotation in
                    guard let magnifier = annotation as? MagnifierAnnotation else { return annotation }
                    return magnifier.withZoom(magnifier.zoom - MagnifierAnnotation.zoomStep)
                }
            }
            return
        }

        // 2. 橡皮擦工具 → 建框选 + captureUndoForPending。参照 capcap L990-998。
        if activeTool == .eraser {
            activeTextField?.commit()
            selectedIndex = nil
            eraserSelection = EraserSelection(start: point, current: point, didDelete: false)
            document?.captureUndoForPending()
            AnnotationCanvasView.eraserCursor.set()
            needsDisplay = true
            return
        }

        // 3. 选择 handle（rotate/curve/tip/...）命中优先于 body 拖拽。
        // 参照 capcap L1000-1020。
        if let kind = hitTestSelectionHandle(at: point),
           let idx = selectedIndex,
           let original = annotation(at: idx) {
            activeTextField?.commit()
            let center = NSPoint(x: original.boundingRect.midX, y: original.boundingRect.midY)
            let startAngle = atan2(point.y - center.y, point.x - center.x)
            handleDragState = HandleDragState(
                kind: kind,
                index: idx,
                original: original,
                startMouse: point,
                startAngle: startAngle,
                startRotation: original.rotation
            )
            document?.captureUndoForPending()
            NSCursor.closedHand.set()
            return
        }

        // 4. 标注 body 命中（顶层优先）→ 选中 + 建 DragState。
        // 任意工具下点击可拖拽标注都开始拖拽，工具仅在空白处接管。
        // 参照 capcap L1022-1057。
        if let idx = hitTestAnnotation(at: point) {
            activeTextField?.commit()
            if isShiftSelecting {
                toggleSelection(of: idx)
                refreshCursorAtCurrentLocation()
                return
            }
            if event.clickCount >= 2,
               selectedIndexes.count == 1,
               selectedIndex == idx,
               let textAnnotation = annotation(at: idx) as? TextAnnotation {
                reEditTextAnnotation(at: idx, annotation: textAnnotation)
                return
            }
            if selectedIndexes.contains(idx), selectedIndexes.count > 1 {
                setSelectedIndexes(selectedIndexes, primary: idx)
            } else {
                selectedIndex = idx
            }
            let originals = Dictionary(
                uniqueKeysWithValues: validSelectedIndexes.compactMap { i -> (Int, Annotation)? in
                    guard let a = annotation(at: i) else { return nil }
                    return (i, a)
                }
            )
            dragState = DragState(
                index: idx,
                startMouse: point,
                originals: originals,
                didDrag: false
            )
            document?.captureUndoForPending()
            NSCursor.closedHand.set()
            return
        }

        // 5. 空白处：提交文字、清选区，工具接管。参照 capcap L1059-1106。
        let wasEditingText = activeTextField != nil
        activeTextField?.commit()
        selectedIndex = nil

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .eraser:
            return
        case .emoji:
            if stampCurrentEmoji(at: point) {
                onEmojiStamped?()
            }
        case .pen:
            currentPenPoints = [point]
        case .marker:
            currentMarkerPoints = [point]
        case .rectangle, .ellipse:
            shapeStart = point
            shapeCurrent = point
            shapeRoughSeed = RoughShapeStyle.randomSeed()
        case .arrow, .line, .mosaic:
            shapeStart = point
            shapeCurrent = point
            shapeRoughSeed = nil
        case .magnifier:
            shapeStart = point
            shapeCurrent = point
            shapeRoughSeed = nil
            magnifierBaseImage = resolveBaseImageForEditing()
        case .number:
            pendingNumberCreate = PendingNumberCreate(start: point, current: point)
        case .text:
            pendingTextCreate = PendingTextCreate(start: point, current: point, wasEditing: wasEditingText)
        case .image:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredAnnotationIndex(nil)

        // handle 拖拽：首次变化时提交 pending 快照，然后应用 handle 变换。
        // 参照 capcap L1113-1119。
        if let state = handleDragState {
            document?.commitPendingUndo()
            applyHandleDrag(state: state, currentMouse: point)
            return
        }

        // body 拖拽：阈值过滤后首次提交 pending，然后按 delta 平移。
        // 参照 capcap L1121-1142。
        if var state = dragState {
            if !state.didDrag {
                let distance = hypot(point.x - state.startMouse.x, point.y - state.startMouse.y)
                guard distance >= dragThreshold else { return }
                state.didDrag = true
                dragState = state
                document?.commitPendingUndo()
            }
            let delta = NSPoint(
                x: point.x - state.startMouse.x,
                y: point.y - state.startMouse.y
            )
            var didMove = false
            for (idx, original) in state.originals {
                guard document?.annotations.indices.contains(idx) ?? false else { continue }
                let translated = annotationForBodyDrag(original, by: delta)
                document?.replace(at: idx, with: translated)
                didMove = true
            }
            if didMove {
                needsDisplay = true
            }
            return
        }

        // 橡皮擦：更新框选并即时删除相交标注。
        if eraserSelection != nil {
            updateEraserSelection(to: point)
            return
        }

        // 编号工具：拖拽拉出箭头尖，实时预览。
        if var pending = pendingNumberCreate {
            pending.current = point
            pendingNumberCreate = pending
            needsDisplay = true
            return
        }
        // 文字工具：仅气泡模式拖拽拉箭头尖；普通模式超阈值取消（避免点击抖动建框）。
        if var pending = pendingTextCreate {
            if currentTextCallout {
                pending.current = point
                pendingTextCreate = pending
                needsDisplay = true
            } else if hypot(point.x - pending.start.x, point.y - pending.start.y) >= dragThreshold {
                pendingTextCreate = nil
            }
            return
        }

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .eraser, .number, .text, .emoji, .image:
            return
        case .pen:
            appendStrokePoint(point, to: &currentPenPoints)
            needsDisplay = true
        case .marker:
            appendStrokePoint(point, to: &currentMarkerPoints)
            needsDisplay = true
        case .rectangle, .ellipse, .arrow, .line, .mosaic, .magnifier:
            shapeCurrent = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 1. handle 拖拽收尾：仅点击未拖则丢弃 pending。参照 capcap L1190-1198。
        if handleDragState != nil {
            handleDragState = nil
            document?.discardPendingUndo()
            needsDisplay = true
            refreshCursorAtCurrentLocation()
            return
        }

        // 2. body 拖拽收尾：未拖丢弃 pending；已拖恢复多选集合。
        // 参照 capcap L1201-1215。
        if let state = dragState {
            dragState = nil
            document?.discardPendingUndo()
            if state.didDrag {
                setSelectedIndexes(Set(state.originals.keys), primary: state.index)
            } else {
                selectedIndex = state.index
            }
            refreshCursorAtCurrentLocation()
            return
        }

        // 3. 橡皮擦收尾：有删除才保留 pending（已 commit），否则丢弃。
        // 参照 capcap L1217-1225。
        if let selection = eraserSelection {
            eraserSelection = nil
            if !selection.didDelete {
                document?.discardPendingUndo()
            }
            needsDisplay = true
            refreshCursorAtCurrentLocation()
            return
        }

        // 4. 编号工具提交：拖拽距离达标则带箭头，否则仅徽章。参照 capcap L1230-1250。
        if let pending = pendingNumberCreate {
            pendingNumberCreate = nil
            let dragDist = hypot(
                pending.current.x - pending.start.x,
                pending.current.y - pending.start.y
            )
            let tip: NSPoint? = dragDist >= NumberAnnotation.arrowMinDistance
                ? pending.current
                : nil
            document?.recordUndo()
            document?.append(NumberAnnotation(
                center: pending.start,
                number: document?.numberCounter ?? 1,
                color: currentColor,
                tip: tip
            ))
            needsDisplay = true
            refreshCursorAtCurrentLocation()
            return
        }

        // 5. 文字工具提交：同次点击刚提交过编辑则跳过。参照 capcap L1253-1276。
        if let pending = pendingTextCreate {
            pendingTextCreate = nil
            if !pending.wasEditing {
                let calloutTip: NSPoint? = {
                    guard currentTextCallout else { return nil }
                    let dragDist = hypot(
                        pending.current.x - pending.start.x,
                        pending.current.y - pending.start.y
                    )
                    return dragDist >= TextAnnotation.calloutArrowMinDistance
                        ? pending.current
                        : nil
                }()
                beginTextEditing(
                    bottomLeft: newTextOrigin(forClickAt: pending.start, fontSize: currentFontSize),
                    fontSize: currentFontSize,
                    color: currentColor,
                    hasStroke: currentTextStroke,
                    hasCallout: currentTextCallout,
                    calloutTip: calloutTip
                )
            }
            return
        }

        guard activeTool != .none else { return }

        switch activeTool {
        case .none, .eraser, .number, .text, .emoji, .image:
            return

        case .pen:
            if let points = currentPenPoints, !points.isEmpty {
                document?.recordUndo()
                document?.append(PenAnnotation(
                    path: points.map { CGPoint(x: $0.x, y: $0.y) },
                    color: currentColor,
                    lineWidth: currentLineWidth
                ))
                currentPenPoints = nil
            }

        case .marker:
            if let points = currentMarkerPoints, !points.isEmpty {
                document?.recordUndo()
                document?.append(MarkerAnnotation(
                    path: points.map { CGPoint(x: $0.x, y: $0.y) },
                    color: currentMarkerColor,
                    lineWidth: currentMarkerLineWidth
                ))
                currentMarkerPoints = nil
            }

        case .mosaic:
            if let start = shapeStart, let end = shapeCurrent {
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2,
                   let baseImage = resolveBaseImageForEditing(),
                   let region = MosaicTool.createMosaicRegion(
                       rect: rect,
                       imageSize: bounds.size,
                       baseImage: baseImage,
                       blockSize: currentMosaicBlockSize
                   ) {
                    document?.recordUndo()
                    document?.append(MosaicAnnotation(
                        rect: region.rect,
                        pixelatedImage: region.pixelatedImage,
                        blockSize: currentMosaicBlockSize
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .magnifier:
            if let start = shapeStart, let end = shapeCurrent,
               let baseImage = magnifierBaseImage {
                let radius = hypot(end.x - start.x, end.y - start.y)
                if radius >= MagnifierAnnotation.minRadius {
                    document?.recordUndo()
                    document?.append(MagnifierAnnotation(
                        center: start,
                        radius: radius,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        zoom: MagnifierAnnotation.defaultZoom,
                        sourceImage: baseImage
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil
            magnifierBaseImage = nil

        case .rectangle:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .rectangle, modifiers: event.modifierFlags)
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    document?.recordUndo()
                    document?.append(RectAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        fillMode: currentShapeFillMode,
                        strokeStyle: currentShapeStrokeStyle,
                        roughStyle: RoughShapeStyle.make(
                            seed: shapeRoughSeed ?? RoughShapeStyle.randomSeed(),
                            rect: rect,
                            lineWidth: currentLineWidth
                        )
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .ellipse:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .ellipse, modifiers: event.modifierFlags)
                let rect = rectFromTwoPoints(start, end)
                if rect.width > 2, rect.height > 2 {
                    document?.recordUndo()
                    document?.append(EllipseAnnotation(
                        rect: rect,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        fillMode: currentShapeFillMode,
                        strokeStyle: currentShapeStrokeStyle,
                        roughStyle: RoughShapeStyle.make(
                            seed: shapeRoughSeed ?? RoughShapeStyle.randomSeed(),
                            rect: rect,
                            lineWidth: currentLineWidth
                        )
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .arrow:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .arrow, modifiers: event.modifierFlags)
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 5 {
                    document?.recordUndo()
                    document?.append(ArrowAnnotation(
                        start: start,
                        end: end,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        style: currentArrowStyle
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil

        case .line:
            if let start = shapeStart, let current = shapeCurrent {
                let end = constrainedShapeEnd(from: start, to: current, tool: .line, modifiers: event.modifierFlags)
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 5 {
                    document?.recordUndo()
                    document?.append(LineAnnotation(
                        start: start,
                        end: end,
                        color: currentColor,
                        lineWidth: currentLineWidth
                    ))
                }
            }
            shapeStart = nil
            shapeCurrent = nil
        }

        shapeRoughSeed = nil
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    override func flagsChanged(with event: NSEvent) {
        if shapeStart != nil, constrainsShapeWithShift(activeTool) {
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    // MARK: - 平移适配

    /// 平移标注：放大镜保持源点焦点，文字保持气泡尾端，其余直接 translate。
    /// 参照 capcap L256-264。
    private func annotationForBodyDrag(_ annotation: Annotation, by delta: NSPoint) -> Annotation {
        if let magnifier = annotation as? MagnifierAnnotation {
            return magnifier.translatedPreservingSourceFocus(by: delta)
        }
        if let text = annotation as? TextAnnotation {
            return text.translatedBodyPreservingCalloutTip(by: delta)
        }
        return annotation.translated(by: delta)
    }

    // MARK: - 命中测试

    /// 顶层优先找到点下的标注索引。参照 capcap L1847-1854。
    func hitTestAnnotation(at point: NSPoint) -> Int? {
        guard let doc = document else { return nil }
        for i in doc.annotations.indices.reversed() {
            if doc.annotations[i].annotation.containsPoint(point) {
                return i
            }
        }
        return nil
    }

    /// 选择 handle 命中（固定优先级：magnifierSource > resize > rotate >
    /// tip > textCalloutTip > arrowEnd > arrowStart > curve）。
    /// 参照 capcap L2745-2820。
    /// 注：返回私有类型 `HandleDragState.Kind`，故方法为 private；
    /// 几何命中本身可经 `hitTestAnnotation` / `hitTestSelectionAction` 单测。
    private func hitTestSelectionHandle(at point: NSPoint) -> HandleDragState.Kind? {
        guard selectedIndexes.count == 1,
              let idx = selectedIndex,
              let annotation = annotation(at: idx) else { return nil }

        if let source = magnifierSourceHandleCenter(for: annotation) {
            let r = AnnotationCanvasView.magnifierSourceHandleSize / 2 + 5
            if hypot(point.x - source.x, point.y - source.y) <= r {
                return .magnifierSource
            }
        }
        if isResizable(annotation) {
            let r = AnnotationCanvasView.resizeHandleSize / 2 + 4
            for anchor in ResizeAnchor.allCases {
                let c = resizeHandlePoint(anchor, for: annotation)
                if hypot(point.x - c.x, point.y - c.y) <= r {
                    return .resize(anchor)
                }
            }
        }
        if annotation.supportsRotation {
            let handleCenter = rotationHandleCenter(for: annotation)
            let r = AnnotationCanvasView.rotateHandleSize / 2 + 2
            if hypot(point.x - handleCenter.x, point.y - handleCenter.y) <= r {
                return .rotate
            }
        }
        if let tip = tipHandleCenter(for: annotation) {
            let r = AnnotationCanvasView.tipHandleSize / 2 + 4
            if hypot(point.x - tip.x, point.y - tip.y) <= r {
                return .tip
            }
        }
        if let tip = textCalloutHandleCenter(for: annotation) {
            let r = AnnotationCanvasView.textCalloutHandleSize / 2 + 4
            if hypot(point.x - tip.x, point.y - tip.y) <= r {
                return .textCalloutTip
            }
        }
        if let end = arrowEndHandleCenter(for: annotation) {
            let r = AnnotationCanvasView.endpointHandleSize / 2 + 4
            if hypot(point.x - end.x, point.y - end.y) <= r {
                return .arrowEnd
            }
        }
        if let start = arrowStartHandleCenter(for: annotation) {
            let r = AnnotationCanvasView.endpointHandleSize / 2 + 4
            if hypot(point.x - start.x, point.y - start.y) <= r {
                return .arrowStart
            }
        }
        if let cp = curveHandleCenter(for: annotation) {
            let r = AnnotationCanvasView.curveHandleSize / 2 + 4
            if hypot(point.x - cp.x, point.y - cp.y) <= r {
                return .curve
            }
        }
        return nil
    }

    /// 选择 action 按钮（delete/edit/number 步进/magnifier zoom）命中。
    /// 参照 capcap L2698-2729。
    func hitTestSelectionAction(at point: NSPoint) -> SelectionAction? {
        guard selectedIndexes.count == 1,
              let idx = selectedIndex,
              let annotation = annotation(at: idx) else { return nil }

        if deleteButtonRect(for: annotation).contains(point) {
            return .delete
        }
        if let editRect = editButtonRect(for: annotation), editRect.contains(point) {
            return .edit
        }
        if let decRect = numberStepButtonRect(for: annotation, increment: false),
           decRect.contains(point) {
            return .decrementNumber
        }
        if let incRect = numberStepButtonRect(for: annotation, increment: true),
           incRect.contains(point) {
            return .incrementNumber
        }
        if let decRect = magnifierZoomButtonRect(for: annotation, increment: false),
           decRect.contains(point) {
            return .zoomOutMagnifier
        }
        if let incRect = magnifierZoomButtonRect(for: annotation, increment: true),
           incRect.contains(point) {
            return .zoomInMagnifier
        }
        return nil
    }

    enum SelectionAction {
        case delete, edit
        case incrementNumber, decrementNumber
        case zoomInMagnifier, zoomOutMagnifier
    }

    private func isResizable(_ annotation: Annotation) -> Bool {
        annotation is RectAnnotation
            || annotation is EllipseAnnotation
            || annotation is MosaicAnnotation
            || annotation is MagnifierAnnotation
            || annotation is ImageAnnotation
            || annotation is EmojiAnnotation
    }

    // MARK: - chrome 几何

    private func selectionBox(for annotation: Annotation) -> NSRect {
        annotation.boundingRect.insetBy(
            dx: -AnnotationCanvasView.selectionBoxPad,
            dy: -AnnotationCanvasView.selectionBoxPad
        )
    }

    /// 把未旋转坐标系下的点按标注旋转（绕包围盒中点）转到画布坐标。
    /// 用于把屏幕空间的 chrome（旋转 handle、delete 按钮）放到随标注旋转的角上。
    private func rotated(_ point: NSPoint, for annotation: Annotation) -> NSPoint {
        let rect = annotation.boundingRect
        let cx = rect.midX
        let cy = rect.midY
        let rot = annotation.supportsRotation ? annotation.rotation : 0
        let dx = point.x - cx
        let dy = point.y - cy
        let cosR = cos(rot)
        let sinR = sin(rot)
        return NSPoint(
            x: cx + dx * cosR - dy * sinR,
            y: cy + dx * sinR + dy * cosR
        )
    }

    private func rotationHandleCenter(for annotation: Annotation) -> NSPoint {
        let box = selectionBox(for: annotation)
        let unrotatedTop = NSPoint(
            x: box.midX,
            y: box.maxY + AnnotationCanvasView.rotateHandleOffset
        )
        return rotated(unrotatedTop, for: annotation)
    }

    private func rotationTetherAnchor(for annotation: Annotation) -> NSPoint {
        let box = selectionBox(for: annotation)
        return rotated(NSPoint(x: box.midX, y: box.maxY + 2), for: annotation)
    }

    private func topRightCorner(for annotation: Annotation) -> NSPoint {
        let box = selectionBox(for: annotation)
        return rotated(NSPoint(x: box.maxX, y: box.maxY), for: annotation)
    }

    /// 曲线 handle：箭头/编号徽章的曲线控制点，无控制点时回退几何中点。
    private func curveHandleCenter(for annotation: Annotation) -> NSPoint? {
        if let arrow = annotation as? ArrowAnnotation { return arrow.curveHandlePoint }
        if let number = annotation as? NumberAnnotation { return number.curveHandlePoint }
        return nil
    }

    /// 编号徽章箭头尖 handle：有 tip 取 tip，否则在徽章上方放一个「桩」
    /// 让用户能拉出新箭头。
    private func tipHandleCenter(for annotation: Annotation) -> NSPoint? {
        guard let number = annotation as? NumberAnnotation else { return nil }
        if let tip = number.tip { return tip }
        return NSPoint(
            x: number.center.x,
            y: number.center.y + NumberAnnotation.arrowMinDistance + 4
        )
    }

    /// 文字气泡 handle：有尾端取尾端，否则取气泡底部中点下方默认偏移。
    private func textCalloutHandleCenter(for annotation: Annotation) -> NSPoint? {
        guard let text = annotation as? TextAnnotation, text.hasCallout else { return nil }
        return rotated(text.calloutHandlePoint, for: annotation)
    }

    /// 放大镜源点 handle：未拖出时在镜头中心，拖出后跟随采样点。
    private func magnifierSourceHandleCenter(for annotation: Annotation) -> NSPoint? {
        guard let magnifier = annotation as? MagnifierAnnotation else { return nil }
        return magnifier.sourceCenter ?? magnifier.center
    }

    /// 箭头/线起点 handle（尾部端点）。
    private func arrowStartHandleCenter(for annotation: Annotation) -> NSPoint? {
        if let arrow = annotation as? ArrowAnnotation { return arrow.start }
        if let line = annotation as? LineAnnotation { return line.start }
        return nil
    }

    /// 箭头/线终点 handle（头部端点）。
    private func arrowEndHandleCenter(for annotation: Annotation) -> NSPoint? {
        if let arrow = annotation as? ArrowAnnotation { return arrow.end }
        if let line = annotation as? LineAnnotation { return line.end }
        return nil
    }

    private func deleteButtonRect(for annotation: Annotation) -> NSRect {
        let s = AnnotationCanvasView.actionButtonSize
        let topRight = topRightCorner(for: annotation)
        return NSRect(x: topRight.x + 4, y: topRight.y - s, width: s, height: s)
    }

    private func editButtonRect(for annotation: Annotation) -> NSRect? {
        guard annotation is TextAnnotation else { return nil }
        let s = AnnotationCanvasView.actionButtonSize
        let topRight = topRightCorner(for: annotation)
        return NSRect(x: topRight.x + 4, y: topRight.y - s * 2 - 4, width: s, height: s)
    }

    /// 编号徽章下方的 -/+ 步进按钮。锚定徽章圆而非包围盒。
    private func numberStepButtonRect(for annotation: Annotation, increment: Bool) -> NSRect? {
        guard let number = annotation as? NumberAnnotation else { return nil }
        let s = AnnotationCanvasView.numberStepButtonSize
        let gap: CGFloat = 4
        let dropBelow: CGFloat = 7
        let centerY = number.center.y - NumberAnnotation.radius - dropBelow - s / 2
        let centerX = increment
            ? number.center.x + gap / 2 + s / 2
            : number.center.x - gap / 2 - s / 2
        return NSRect(x: centerX - s / 2, y: centerY - s / 2, width: s, height: s)
    }

    /// 放大镜下方的 -/+ zoom 步进按钮。
    private func magnifierZoomButtonRect(for annotation: Annotation, increment: Bool) -> NSRect? {
        guard let magnifier = annotation as? MagnifierAnnotation else { return nil }
        let s = AnnotationCanvasView.numberStepButtonSize
        let gap: CGFloat = 4
        let dropBelow: CGFloat = 9
        let centerY = magnifier.center.y - magnifier.radius - dropBelow - s / 2
        let centerX = increment
            ? magnifier.center.x + gap / 2 + s / 2
            : magnifier.center.x - gap / 2 - s / 2
        return NSRect(x: centerX - s / 2, y: centerY - s / 2, width: s, height: s)
    }

    private func resizeHandlePoint(_ anchor: ResizeAnchor, for annotation: Annotation) -> NSPoint {
        rotated(anchor.point(in: annotation.boundingRect), for: annotation)
    }

    // MARK: - handle 拖拽应用

    /// 把 handle 拖拽的当前鼠标位置翻译为标注变异。参照 capcap L2829-3039。
    private func applyHandleDrag(state: HandleDragState, currentMouse: NSPoint) {
        guard document?.annotations.indices.contains(state.index) ?? false else { return }

        switch state.kind {
        case .rotate:
            let original = state.original
            let center = NSPoint(x: original.boundingRect.midX, y: original.boundingRect.midY)
            let currentAngle = atan2(currentMouse.y - center.y, currentMouse.x - center.x)
            var newRotation = state.startRotation + (currentAngle - state.startAngle)
            // Shift 吸附到 15° 整数倍。
            if NSEvent.modifierFlags.contains(.shift) {
                let step = CGFloat.pi / 12
                newRotation = (newRotation / step).rounded() * step
            }
            document?.replace(at: state.index, with: original.withRotation(newRotation))

        case .curve:
            // 拖到几何中点附近回退为直线箭杆。
            if let arrow = state.original as? ArrowAnnotation {
                let mid = arrow.defaultCurveMid
                if hypot(currentMouse.x - mid.x, currentMouse.y - mid.y) < 4 {
                    document?.replace(at: state.index, with: arrow.withControlPoint(nil))
                } else {
                    document?.replace(at: state.index, with: arrow.withControlPoint(currentMouse))
                }
            } else if let number = state.original as? NumberAnnotation,
                      let mid = number.defaultCurveMid {
                if hypot(currentMouse.x - mid.x, currentMouse.y - mid.y) < 4 {
                    document?.replace(at: state.index, with: number.withControlPoint(nil))
                } else {
                    document?.replace(at: state.index, with: number.withControlPoint(currentMouse))
                }
            }

        case .tip:
            guard let number = state.original as? NumberAnnotation else { return }
            let dist = hypot(currentMouse.x - number.center.x, currentMouse.y - number.center.y)
            if dist < NumberAnnotation.arrowMinDistance {
                document?.replace(at: state.index, with: number.withTip(nil))
            } else {
                document?.replace(at: state.index, with: number.withTip(currentMouse))
            }

        case .textCalloutTip:
            guard let text = state.original as? TextAnnotation, text.hasCallout else { return }
            let point = text.unrotate(currentMouse)
            if text.calloutBodyRect.insetBy(dx: -2, dy: -2).contains(point) {
                document?.replace(at: state.index, with: text.withCalloutTip(nil))
                break
            }
            let anchor = text.calloutAnchorPoint(for: point)
            let dist = hypot(point.x - anchor.x, point.y - anchor.y)
            if dist <= TextAnnotation.calloutArrowMinDistance {
                document?.replace(at: state.index, with: text.withCalloutTip(nil))
            } else {
                document?.replace(at: state.index, with: text.withCalloutTip(point))
            }

        case .magnifierSource:
            guard let magnifier = state.original as? MagnifierAnnotation else { return }
            let point = clampedToCanvas(currentMouse)
            let dist = hypot(point.x - magnifier.center.x, point.y - magnifier.center.y)
            let source = dist < MagnifierAnnotation.sourceResetDistance ? nil : point
            document?.replace(at: state.index, with: magnifier.withSourceCenter(source))

        case .arrowStart:
            if let arrow = state.original as? ArrowAnnotation {
                let newStart = constrainedEndpoint(currentMouse, fixedPoint: arrow.end)
                document?.replace(at: state.index, with: arrow.withStart(newStart))
            } else if let line = state.original as? LineAnnotation {
                let newStart = constrainedEndpoint(currentMouse, fixedPoint: line.end)
                document?.replace(at: state.index, with: line.withStart(newStart))
            }

        case .arrowEnd:
            if let arrow = state.original as? ArrowAnnotation {
                let newEnd = constrainedEndpoint(currentMouse, fixedPoint: arrow.start)
                document?.replace(at: state.index, with: arrow.withEnd(newEnd))
            } else if let line = state.original as? LineAnnotation {
                let newEnd = constrainedEndpoint(currentMouse, fixedPoint: line.start)
                document?.replace(at: state.index, with: line.withEnd(newEnd))
            }

        case .resize(let anchor):
            applyResizeDrag(state: state, anchor: anchor, currentMouse: currentMouse)
        }

        needsDisplay = true
    }

    /// resize handle 拖拽：按标注类型分发到放大镜（圆形保圆心）、
    /// 马赛克（重新像素化）、矩形/椭圆/图片/emoji（旋转坐标 resize）。
    /// 参照 capcap L2932-3035。
    private func applyResizeDrag(state: HandleDragState, anchor: ResizeAnchor, currentMouse: NSPoint) {
        let shiftIsDown = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)

        if let magnifier = state.original as? MagnifierAnnotation {
            // 圆形镜头：圆心不动，半径 = 光标到圆心距离。八 handle 行为一致。
            let r = hypot(currentMouse.x - magnifier.center.x, currentMouse.y - magnifier.center.y)
            guard r >= MagnifierAnnotation.minRadius else { return }
            document?.replace(at: state.index, with: magnifier.withRadius(r))
        } else if let mosaic = state.original as? MosaicAnnotation {
            let newRect = resizedRect(
                from: mosaic.rect,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: 4,
                constraint: shiftIsDown ? .preserveAspectRatio : .none
            )
            guard newRect.width >= 4, newRect.height >= 4,
                  let baseImage = resolveBaseImageForEditing(),
                  let region = MosaicTool.createMosaicRegion(
                      rect: newRect,
                      imageSize: bounds.size,
                      baseImage: baseImage,
                      blockSize: mosaic.blockSize
                  ) else { return }
            document?.replace(at: state.index, with: MosaicAnnotation(
                uuid: mosaic.uuid,
                rect: region.rect,
                pixelatedImage: region.pixelatedImage,
                blockSize: mosaic.blockSize
            ))
        } else if let rect = state.original as? RectAnnotation {
            let newRect = resizedRotatedRect(
                from: rect.rect,
                rotation: rect.rotation,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: 4,
                constraint: shiftIsDown ? .square : .none
            )
            guard newRect.width >= 4, newRect.height >= 4 else { return }
            document?.replace(at: state.index, with: RectAnnotation(
                uuid: rect.uuid,
                rect: newRect,
                color: rect.color,
                lineWidth: rect.lineWidth,
                fillMode: rect.fillMode,
                strokeStyle: rect.strokeStyle,
                roughStyle: rect.roughStyle.tuned(for: newRect, lineWidth: rect.lineWidth),
                rotation: rect.rotation
            ))
        } else if let ellipse = state.original as? EllipseAnnotation {
            let newRect = resizedRotatedRect(
                from: ellipse.rect,
                rotation: ellipse.rotation,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: 4,
                constraint: shiftIsDown ? .square : .none
            )
            guard newRect.width >= 4, newRect.height >= 4 else { return }
            document?.replace(at: state.index, with: EllipseAnnotation(
                uuid: ellipse.uuid,
                rect: newRect,
                color: ellipse.color,
                lineWidth: ellipse.lineWidth,
                fillMode: ellipse.fillMode,
                strokeStyle: ellipse.strokeStyle,
                roughStyle: ellipse.roughStyle.tuned(for: newRect, lineWidth: ellipse.lineWidth),
                rotation: ellipse.rotation
            ))
        } else if let image = state.original as? ImageAnnotation {
            let newRect = resizedRotatedRect(
                from: image.rect,
                rotation: image.rotation,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: 12,
                constraint: shiftIsDown ? .preserveAspectRatio : .none
            )
            guard newRect.width >= 12, newRect.height >= 12 else { return }
            document?.replace(at: state.index, with: image.withRect(newRect))
        } else if let emoji = state.original as? EmojiAnnotation {
            let newRect = resizedRotatedRect(
                from: emoji.rect,
                rotation: emoji.rotation,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: 12,
                constraint: shiftIsDown ? .square : .none
            )
            guard newRect.width >= 12, newRect.height >= 12 else { return }
            document?.replace(at: state.index, with: emoji.withRect(newRect))
        }
    }

    /// 轴对齐 resize（rotation = 0 的便捷入口，马赛克用）。
    /// 参照 capcap L3041-3081。
    private func resizedRect(
        from original: NSRect,
        anchor: ResizeAnchor,
        currentMouse: NSPoint,
        minimumSize: CGFloat,
        constraint: ResizeConstraint = .none
    ) -> NSRect {
        if constraint != .none {
            return resizedRotatedRect(
                from: original,
                rotation: 0,
                anchor: anchor,
                currentMouse: currentMouse,
                minimumSize: minimumSize,
                constraint: constraint
            )
        }
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if anchor.movesMinX { minX = currentMouse.x }
        if anchor.movesMaxX { maxX = currentMouse.x }
        if anchor.movesMinY { minY = currentMouse.y }
        if anchor.movesMaxY { maxY = currentMouse.y }
        let width = abs(maxX - minX)
        let height = abs(maxY - minY)
        guard width >= minimumSize, height >= minimumSize else { return original }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: width, height: height)
    }

    /// 旋转坐标下的 resize 数学：把光标位移反旋转到标注局部坐标系，
    /// 按锚点方向更新半宽/半高，可选 preserveAspectRatio/square 约束，
    /// 最后把新中心正向旋回画布坐标。参照 capcap L3083-3165。
    private func resizedRotatedRect(
        from original: NSRect,
        rotation: CGFloat,
        anchor: ResizeAnchor,
        currentMouse: NSPoint,
        minimumSize: CGFloat,
        constraint: ResizeConstraint = .none
    ) -> NSRect {
        let originalHalfWidth = original.width / 2
        let originalHalfHeight = original.height / 2
        let originalCenter = NSPoint(x: original.midX, y: original.midY)
        guard original.width > 0, original.height > 0 else { return original }

        let xSign: CGFloat? = anchor.movesMinX ? -1 : (anchor.movesMaxX ? 1 : nil)
        let ySign: CGFloat? = anchor.movesMinY ? -1 : (anchor.movesMaxY ? 1 : nil)

        let fixedLocal = NSPoint(
            x: xSign.map { -$0 * originalHalfWidth } ?? 0,
            y: ySign.map { -$0 * originalHalfHeight } ?? 0
        )
        let fixedWorld = point(originalCenter, adding: rotatedVector(fixedLocal, by: rotation))
        let deltaLocal = unrotatedVector(delta(from: fixedWorld, to: currentMouse), by: rotation)

        let proposedWidth = xSign.map { $0 * deltaLocal.x } ?? original.width
        let proposedHeight = ySign.map { $0 * deltaLocal.y } ?? original.height
        var signedWidth = proposedWidth
        var signedHeight = proposedHeight

        func direction(for value: CGFloat) -> CGFloat { value < 0 ? -1 : 1 }

        if constraint == .preserveAspectRatio, xSign != nil || ySign != nil {
            let scale: CGFloat
            switch (xSign, ySign) {
            case (.some, .some):
                let denominator = original.width * original.width + original.height * original.height
                scale = denominator > 0
                    ? (original.width * abs(proposedWidth) + original.height * abs(proposedHeight)) / denominator
                    : 1
            case (.some, .none):
                scale = abs(proposedWidth) / original.width
            case (.none, .some):
                scale = abs(proposedHeight) / original.height
            case (.none, .none):
                scale = 1
            }
            guard scale.isFinite else { return original }
            signedWidth = (xSign == nil ? 1 : direction(for: proposedWidth)) * original.width * scale
            signedHeight = (ySign == nil ? 1 : direction(for: proposedHeight)) * original.height * scale
        } else if constraint == .square, xSign != nil || ySign != nil {
            let side: CGFloat
            switch (xSign, ySign) {
            case (.some, .some): side = max(abs(proposedWidth), abs(proposedHeight))
            case (.some, .none): side = abs(proposedWidth)
            case (.none, .some): side = abs(proposedHeight)
            case (.none, .none): side = min(original.width, original.height)
            }
            guard side.isFinite else { return original }
            signedWidth = (xSign == nil ? 1 : direction(for: proposedWidth)) * side
            signedHeight = (ySign == nil ? 1 : direction(for: proposedHeight)) * side
        }

        let halfWidth = abs(signedWidth) / 2
        let halfHeight = abs(signedHeight) / 2
        let centerLocal = NSPoint(
            x: xSign.map { $0 * signedWidth / 2 } ?? 0,
            y: ySign.map { $0 * signedHeight / 2 } ?? 0
        )
        let center = point(fixedWorld, adding: rotatedVector(centerLocal, by: rotation))
        return NSRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        )
    }

    private func constrainedEndpoint(_ currentMouse: NSPoint, fixedPoint: NSPoint) -> NSPoint {
        guard NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        else { return currentMouse }
        return axisLockedEnd(from: fixedPoint, to: currentMouse)
    }

    private func rotatedVector(_ vector: NSPoint, by rotation: CGFloat) -> NSPoint {
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        return NSPoint(
            x: vector.x * cosR - vector.y * sinR,
            y: vector.x * sinR + vector.y * cosR
        )
    }

    private func unrotatedVector(_ vector: NSPoint, by rotation: CGFloat) -> NSPoint {
        rotatedVector(vector, by: -rotation)
    }

    private func point(_ point: NSPoint, adding vector: NSPoint) -> NSPoint {
        NSPoint(x: point.x + vector.x, y: point.y + vector.y)
    }

    private func delta(from start: NSPoint, to end: NSPoint) -> NSPoint {
        NSPoint(x: end.x - start.x, y: end.y - start.y)
    }

    private func clampedToCanvas(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    // MARK: - 橡皮擦

    private func updateEraserSelection(to point: NSPoint) {
        guard var selection = eraserSelection else { return }
        selection.current = point
        eraseAnnotations(in: rectFromTwoPoints(selection.start, point), selection: &selection)
        eraserSelection = selection
        needsDisplay = true
    }

    /// 框选相交删除：相交即删。首次真正删除时提交 pending（合并为单 undo 步）。
    /// 参照 capcap L1892-1905。
    private func eraseAnnotations(in rect: NSRect, selection: inout EraserSelection) {
        guard rect.width >= 1 || rect.height >= 1 else { return }
        guard let doc = document else { return }
        let kept = doc.annotations.filter { !annotationSelectionBounds($0.annotation).intersects(rect) }
        guard kept.count != doc.annotations.count else { return }

        if !selection.didDelete {
            doc.commitPendingUndo()
            selection.didDelete = true
        }
        // 重建栈：保留未删标注，丢弃被删标注的索引。
        // 直接重新赋值会绕过 document 的私有 setter；用 removeAll + 逐个 append。
        // 但这会破坏 undo 快照的 annotations 引用——此处用受控的「原地重置」。
        doc.replaceAnnotationsPreservingHistory(kept)
        selectedIndex = nil
        resetNumberCounterIfNumberAnnotationsAreGone()
        refreshCursorAtCurrentLocation()
    }

    /// 标注的选中包围盒（支持旋转时取四角旋转后的外接矩形）。
    private func annotationSelectionBounds(_ annotation: Annotation) -> NSRect {
        let rect = annotation.boundingRect
        guard annotation.supportsRotation, annotation.rotation != 0 else { return rect }
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ].map { rotated($0, for: annotation) }
        guard let first = corners.first else { return rect }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in corners.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - 子工具栏调整（颜色/字号滑块）

    /// 开始一次子工具栏滑块调整：捕获 pending 快照（无选中时 no-op）。
    func beginSelectionAdjustment() {
        guard selectedIndexes.count == 1 else { return }
        document?.captureUndoForPending()
        selectionAdjustmentDirty = false
    }

    /// 提交滑块调整：有实际变更才提交，否则丢弃。
    func commitSelectionAdjustment() {
        if selectionAdjustmentDirty {
            document?.commitPendingUndo()
        } else {
            document?.discardPendingUndo()
        }
        selectionAdjustmentDirty = false
    }

    /// 原子变更选中标注（颜色色块、离散尺寸点等无拖拽批处理）。
    /// 捕获 undo、应用变换、重绘。参照 capcap L773-782。
    func mutateSelectedAnnotationAtomic(_ transform: (Annotation) -> Annotation) {
        guard selectedIndexes.count == 1,
              let idx = selectedIndex,
              let original = annotation(at: idx) else { return }
        let updated = transform(original)
        guard !annotationsEqualEnough(updated, original) else { return }
        document?.recordUndo()
        document?.replace(at: idx, with: updated)
        needsDisplay = true
    }

    /// 滑块拖拽中的实时变更，调用方负责 begin/commit 配对。
    func mutateSelectedAnnotationLive(_ transform: (Annotation) -> Annotation) {
        guard selectedIndexes.count == 1,
              let idx = selectedIndex,
              let original = annotation(at: idx) else { return }
        let updated = transform(original)
        guard !annotationsEqualEnough(updated, original) else { return }
        document?.replace(at: idx, with: updated)
        selectionAdjustmentDirty = true
        needsDisplay = true
    }

    /// 马赛克块大小滑块专用：变更时重新像素化。
    func mutateSelectedMosaicBlockSizeLive(_ blockSize: CGFloat) {
        guard let baseImage = resolveBaseImageForEditing() else { return }
        mutateSelectedAnnotationLive { annotation in
            guard let mosaic = annotation as? MosaicAnnotation,
                  let region = MosaicTool.createMosaicRegion(
                      rect: mosaic.rect,
                      imageSize: bounds.size,
                      baseImage: baseImage,
                      blockSize: blockSize
                  )
            else { return annotation }
            return MosaicAnnotation(
                uuid: mosaic.uuid,
                rect: region.rect,
                pixelatedImage: region.pixelatedImage,
                blockSize: blockSize
            )
        }
    }

    /// 廉价身份比较：防止点击已选中色块时注册无谓 undo 条目。
    /// 参照 capcap L885-942。
    private func annotationsEqualEnough(_ a: Annotation, _ b: Annotation) -> Bool {
        if let a = a as? TextAnnotation, let b = b as? TextAnnotation {
            return a.text == b.text && a.origin == b.origin
                && a.fontSize == b.fontSize && a.rotation == b.rotation
                && a.color == b.color && a.hasStroke == b.hasStroke
                && a.hasCallout == b.hasCallout && a.calloutTip == b.calloutTip
        }
        if let a = a as? PenAnnotation, let b = b as? PenAnnotation {
            return a.path == b.path && a.lineWidth == b.lineWidth
                && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? MarkerAnnotation, let b = b as? MarkerAnnotation {
            return a.path == b.path && a.lineWidth == b.lineWidth
                && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? RectAnnotation, let b = b as? RectAnnotation {
            return a.rect == b.rect && a.lineWidth == b.lineWidth
                && a.fillMode == b.fillMode && a.strokeStyle == b.strokeStyle
                && a.roughStyle == b.roughStyle
                && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? EllipseAnnotation, let b = b as? EllipseAnnotation {
            return a.rect == b.rect && a.lineWidth == b.lineWidth
                && a.fillMode == b.fillMode && a.strokeStyle == b.strokeStyle
                && a.roughStyle == b.roughStyle
                && a.rotation == b.rotation && a.color == b.color
        }
        if let a = a as? ArrowAnnotation, let b = b as? ArrowAnnotation {
            return a.start == b.start && a.end == b.end
                && a.controlPoint == b.controlPoint && a.style == b.style
                && a.lineWidth == b.lineWidth && a.color == b.color
        }
        if let a = a as? LineAnnotation, let b = b as? LineAnnotation {
            return a.start == b.start && a.end == b.end
                && a.lineWidth == b.lineWidth && a.color == b.color
        }
        if let a = a as? NumberAnnotation, let b = b as? NumberAnnotation {
            return a.center == b.center && a.tip == b.tip
                && a.controlPoint == b.controlPoint && a.number == b.number
                && a.color == b.color
        }
        if let a = a as? MosaicAnnotation, let b = b as? MosaicAnnotation {
            return a.rect == b.rect && a.blockSize == b.blockSize
        }
        if let a = a as? MagnifierAnnotation, let b = b as? MagnifierAnnotation {
            return a.center == b.center && a.radius == b.radius
                && a.color == b.color && a.lineWidth == b.lineWidth
                && a.zoom == b.zoom && a.sourceImage === b.sourceImage
                && a.sourceCenter == b.sourceCenter
        }
        if let a = a as? ImageAnnotation, let b = b as? ImageAnnotation {
            return a.image === b.image && a.rect == b.rect && a.rotation == b.rotation
        }
        if let a = a as? EmojiAnnotation, let b = b as? EmojiAnnotation {
            return a.emoji == b.emoji && a.rect == b.rect && a.rotation == b.rotation
        }
        return false
    }

    private func resetNumberCounterIfNumberAnnotationsAreGone() {
        // 委托给 document 在 remove 后处理；此处仅触发重算。
        // document 的 replaceAnnotationsPreservingHistory 内不自动重算，
        // 由这里补一次。
        guard let doc = document else { return }
        if !doc.annotations.contains(where: { $0.annotation is NumberAnnotation }) {
            doc.resetNumberCounterIfNeeded()
        }
    }

    // MARK: - 删除/剪贴板/全选

    /// 删除当前选中标注。橡皮擦拖拽中或文字编辑中不响应。
    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        let indexes = validSelectedIndexes
        guard activeTextField == nil, !indexes.isEmpty else { return false }
        document?.recordUndo()
        document?.remove(atIndexes: indexes)
        selectedIndex = nil
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    func deleteSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        guard AnnotationCanvasView.isSelectionDeleteKey(event) else { return false }
        return deleteSelectedAnnotation()
    }

    /// 方向键微移选中标注 1pt。
    func nudgeSelectedAnnotationFromKeyboard(for event: NSEvent) -> Bool {
        let indexes = validSelectedIndexes
        guard activeTextField == nil,
              let delta = AnnotationCanvasView.selectionNudgeDelta(for: event),
              !indexes.isEmpty else { return false }
        document?.recordUndo()
        for idx in indexes {
            guard let a = annotation(at: idx) else { continue }
            document?.replace(at: idx, with: a.translated(by: delta))
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    func undoFromKeyboard(for event: NSEvent) -> Bool {
        guard AnnotationCanvasView.isUndoKey(event) else { return false }
        return undo()
    }

    func redoFromKeyboard(for event: NSEvent) -> Bool {
        guard AnnotationCanvasView.isRedoKey(event) else { return false }
        return redo()
    }

    @discardableResult
    func undo() -> Bool {
        guard document?.undo() == true else { return false }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard document?.redo() == true else { return false }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    func handleAnnotationClipboardShortcutFromKeyboard(for event: NSEvent) -> Bool {
        guard let shortcut = AnnotationCanvasView.commandShortcutCharacter(for: event) else { return false }
        switch shortcut {
        case "x": return cutSelectedAnnotation()
        case "c": return copySelectedAnnotation()
        case "v": return pasteCopiedAnnotation()
        case "a": return selectAllAnnotations()
        default: return false
        }
    }

    @discardableResult
    func copySelectedAnnotation() -> Bool {
        let indexes = validSelectedIndexes
        guard activeTextField == nil, indexes.count == 1 else { return false }
        Self.annotationPasteboard = indexes.compactMap { annotation(at: $0) }
        return true
    }

    @discardableResult
    func cutSelectedAnnotation() -> Bool {
        guard copySelectedAnnotation() else { return false }
        return deleteSelectedAnnotation()
    }

    @discardableResult
    func pasteCopiedAnnotation() -> Bool {
        let sources = Self.annotationPasteboard
        guard activeTextField == nil, sources.count == 1 else { return false }
        let offset = pasteOffset(forPasting: sources)
        let pasted = sources.map { $0.translated(by: offset) }
        let firstNewIndex = document?.annotations.count ?? 0
        document?.recordUndo()
        pasted.forEach { document?.append($0) }
        if let last = document?.annotations.indices.last {
            setSelectedIndexes(Set(firstNewIndex...last), primary: last)
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    @discardableResult
    func selectAllAnnotations() -> Bool {
        guard let doc = document, activeTextField == nil, !doc.annotations.isEmpty else { return false }
        setSelectedIndexes(Set(doc.annotations.indices), primary: doc.annotations.indices.last)
        refreshCursorAtCurrentLocation()
        return true
    }

    private func pasteOffset(forPasting annotations: [Annotation]) -> NSPoint {
        if let cursorPoint = currentMousePointInCanvas(), bounds.contains(cursorPoint) {
            let rect = combinedBoundingRect(for: annotations)
            return NSPoint(x: cursorPoint.x - rect.midX, y: cursorPoint.y - rect.midY)
        }
        return AnnotationCanvasView.defaultPasteOffset
    }

    private func combinedBoundingRect(for annotations: [Annotation]) -> NSRect {
        guard let first = annotations.first?.boundingRect else { return .zero }
        return annotations.dropFirst().reduce(first) { $0.union($1.boundingRect) }
    }

    private func currentMousePointInCanvas() -> NSPoint? {
        guard let window else { return nil }
        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        return convert(mouseInWindow, from: nil)
    }

    // MARK: - emoji / image 插入

    /// emoji 工具：在指定点盖印当前 emoji。
    @discardableResult
    private func stampCurrentEmoji(at point: NSPoint) -> Bool {
        guard let currentEmoji else { return false }
        activeTextField?.commit()
        let rect = emojiRect(centeredAt: point)
        document?.recordUndo()
        document?.append(EmojiAnnotation(emoji: currentEmoji, rect: rect))
        if let last = document?.annotations.indices.last {
            selectedIndex = last
        }
        emojiPreviewPoint = point
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    /// 由控制器调用插入指定 emoji（工具栏入口）。
    @discardableResult
    func insertEmoji(_ emoji: String) -> Bool {
        activeTextField?.commit()
        let rect = emojiRect(centeredAt: insertionCenter())
        document?.recordUndo()
        document?.append(EmojiAnnotation(emoji: emoji, rect: rect))
        if let last = document?.annotations.indices.last {
            selectedIndex = last
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    /// 由控制器调用插入图片。
    @discardableResult
    func insertImage(_ image: NSImage) -> Bool {
        activeTextField?.commit()
        let size = fittedInsertedImageSize(for: image)
        guard size.width > 0, size.height > 0 else { return false }
        let rect = insertionRect(size: size)
        document?.recordUndo()
        document?.append(ImageAnnotation(image: image, rect: rect))
        if let last = document?.annotations.indices.last {
            selectedIndex = last
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
        return true
    }

    private func fittedInsertedImageSize(for image: NSImage) -> NSSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let maxWidth = min(max(24, bounds.width - 16), 360)
        let maxHeight = min(max(24, bounds.height - 16), 360)
        let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
        return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func insertionRect(size: NSSize) -> NSRect {
        let center = insertionCenter()
        return NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func emojiRect(centeredAt point: NSPoint) -> NSRect {
        let size = NSSize(width: 44, height: 44)
        return NSRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func insertionCenter() -> NSPoint {
        if let cursorPoint = currentMousePointInCanvas(), bounds.contains(cursorPoint) {
            return cursorPoint
        }
        return NSPoint(x: bounds.midX, y: bounds.midY)
    }

    // MARK: - 文字编辑生命周期

    /// 强制提交进行中的文字编辑。控制器在切工具/保存/确认时调用。
    func commitActiveTextEditing() {
        activeTextField?.commit()
    }

    /// 点击点下移一行高度，作为新文字框的底左角。参照 capcap L1943-1949。
    private func newTextOrigin(forClickAt point: NSPoint, fontSize: CGFloat) -> NSPoint {
        let font = TextAnnotation.font(forSize: fontSize)
        return NSPoint(
            x: point.x,
            y: point.y - TextAnnotation.lineHeight(for: font)
        )
    }

    /// 重新编辑现有文字标注：移除原标注、建浮层预填文字。
    /// **必须延后一拍**（DispatchQueue.main.async）——在 mouseDown 栈帧内
    /// makeFirstResponder 会被立刻 resign，导致浮层还没显示就被提交拆除。
    /// 参照 capcap L396-414。
    private func reEditTextAnnotation(at index: Int, annotation: TextAnnotation) {
        selectedIndex = nil
        let captured = annotation
        let capturedIndex = index
        DispatchQueue.main.async { [weak self] in
            self?.beginTextEditing(
                bottomLeft: captured.origin,
                fontSize: captured.fontSize,
                color: captured.color,
                hasStroke: captured.hasStroke,
                hasCallout: captured.hasCallout,
                calloutTip: captured.calloutTip,
                initialText: captured.text,
                rotation: captured.rotation,
                replacingIndex: capturedIndex
            )
        }
    }

    /// 创建文字编辑浮层。参照 capcap L1951-2037。
    private func beginTextEditing(
        bottomLeft: NSPoint,
        fontSize: CGFloat,
        color: NSColor,
        hasStroke: Bool,
        hasCallout: Bool,
        calloutTip: NSPoint? = nil,
        initialText: String = "",
        rotation: CGFloat = 0,
        replacingIndex: Int? = nil
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let lineHeight = TextAnnotation.lineHeight(for: font)

        // 在移除原标注前捕获 pending 快照，保证 undo 能干净恢复。
        document?.captureUndoForPending()

        if let idx = replacingIndex,
           let doc = document,
           doc.annotations.indices.contains(idx),
           let original = doc.annotations[idx].annotation as? TextAnnotation {
            // 移除原标注（编辑期间不在栈中绘制），暂存以便 cancel 回插。
            doc.removeAnnotationsAtIndicesPreservingHistory([idx])
            editingOriginalAnnotation = original
            editingOriginalIndex = idx
            needsDisplay = true
        } else {
            editingOriginalAnnotation = nil
            editingOriginalIndex = nil
        }

        let initialSize = TextAnnotation.editorSize(for: initialText, font: font)
        let contentHeight = max(initialSize.height, lineHeight)
        let fieldRect: NSRect
        if hasCallout {
            fieldRect = NSRect(
                x: bottomLeft.x - TextAnnotation.calloutHorizontalPadding,
                y: bottomLeft.y - TextAnnotation.calloutVerticalPadding,
                width: initialSize.width + TextAnnotation.calloutHorizontalPadding * 2,
                height: contentHeight + TextAnnotation.calloutVerticalPadding * 2
            )
        } else {
            fieldRect = NSRect(
                x: bottomLeft.x,
                y: bottomLeft.y,
                width: initialSize.width,
                height: contentHeight
            )
        }

        let field = EditableTextField(frame: fieldRect)
        field.font = font
        field.annotationColor = color
        field.hasStroke = hasStroke
        field.hasCallout = hasCallout
        field.calloutTip = calloutTip
        field.rotation = rotation
        field.stringValue = initialText
        field.onCommit = { [weak self, weak field] text in
            self?.handleTextCommit(text: text, field: field)
        }
        field.onCancel = { [weak self, weak field] in
            self?.handleTextCancel(field: field)
        }
        field.onChange = { [weak self] in
            self?.needsDisplay = true
        }

        addSubview(field)
        activeTextField = field
        field.sizeToFitText()
        window?.makeFirstResponder(field)
        // 不要用 selectText(nil)——它会再次 makeFirstResponder，导致 AppKit
        // 拆掉刚建的 cell editor 又重建，触发 controlTextDidEndEditing 被当作
        // commit 而提前拆除浮层。直接设 currentEditor().selectedRange。
        if !initialText.isEmpty, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (initialText as NSString).length)
        }
    }

    /// 提交文字：移除浮层、构造 TextAnnotation 入栈、处理 undo。
    /// 参照 capcap L2039-2081。
    private func handleTextCommit(text: String, field: EditableTextField?) {
        guard let field else { return }
        field.removeFromSuperview()
        if activeTextField === field { activeTextField = nil }
        if activeTool == .text {
            window?.makeFirstResponder(self)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasReEdit = editingOriginalIndex != nil
        if !trimmed.isEmpty {
            let font = field.font ?? NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
            let newAnnotation = TextAnnotation(
                text: text,
                origin: field.annotationOrigin,
                color: field.annotationColor,
                fontSize: font.pointSize,
                rotation: field.rotation,
                hasStroke: field.hasStroke,
                hasCallout: field.hasCallout,
                calloutTip: field.calloutTip
            )
            if let idx = editingOriginalIndex, let doc = document {
                let safeIdx = min(idx, doc.annotations.count)
                doc.insertAnnotationAtPreservingHistory(newAnnotation, at: safeIdx)
            } else {
                document?.append(newAnnotation)
            }
        }
        editingOriginalAnnotation = nil
        editingOriginalIndex = nil
        // 净变更 = 新增标注或重编辑（重编辑总是替换或移除原标注）；
        // 空白新建无变更则丢弃 pending。
        if !trimmed.isEmpty || wasReEdit {
            document?.commitPendingUndo()
        } else {
            document?.discardPendingUndo()
        }
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    /// 取消文字编辑：移除浮层、回插原标注、丢弃 pending。
    /// 参照 capcap L2083-2101。
    private func handleTextCancel(field: EditableTextField?) {
        guard let field else { return }
        field.removeFromSuperview()
        if activeTextField === field { activeTextField = nil }
        if activeTool == .text {
            window?.makeFirstResponder(self)
        }
        if let original = editingOriginalAnnotation, let idx = editingOriginalIndex {
            document?.insertAnnotationAtPreservingHistory(original, at: min(idx, document?.annotations.count ?? 0))
        }
        editingOriginalAnnotation = nil
        editingOriginalIndex = nil
        document?.discardPendingUndo()
        needsDisplay = true
        refreshCursorAtCurrentLocation()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 底图：长截图 preview 优先。
        if let image = resolveBaseImageForEditing() {
            image.draw(in: NSRect(origin: .zero, size: bounds.size))
        }

        guard let doc = document else { return }

        // 全部已提交标注（旋转经 drawApplyingTransforms 应用）。
        for any in doc.annotations {
            any.annotation.drawApplyingTransforms(in: context, bounds: bounds)
        }

        // 活动文字浮层背后的气泡背景（让浮层与气泡视觉一致）。
        drawActiveTextCalloutBackground(in: context)

        let selected = validSelectedIndexes
        // hover 高亮（选中态下不绘制）。
        if let idx = hoveredAnnotationIndex,
           doc.annotations.indices.contains(idx),
           !selected.contains(idx) {
            drawHoverHighlight(for: doc.annotations[idx].annotation, in: context)
        }

        // 选中 chrome——单选画全套 handle，多选只画虚线框。
        if selected.count == 1, let idx = selected.first {
            drawSelectionHandles(for: doc.annotations[idx].annotation, in: context)
        } else {
            for idx in selected {
                drawSelectionOutline(for: doc.annotations[idx].annotation, in: context)
            }
        }

        // 进行中的画笔笔迹（平滑后实时预览，与提交一致）。
        if let points = currentPenPoints, !points.isEmpty {
            let path = NSBezierPath.smoothed(through: points)
            currentColor.setStroke()
            path.lineWidth = currentLineWidth
            path.stroke()
        }
        // 进行中的荧光笔笔迹（半透明粗笔，透明度层防加深）。
        if let points = currentMarkerPoints, !points.isEmpty {
            let path = NSBezierPath.smoothed(through: points)
            NSGraphicsContext.saveGraphicsState()
            let stroke = currentMarkerColor.withAlphaComponent(1.0)
            stroke.setStroke()
            path.lineWidth = currentMarkerLineWidth * MarkerAnnotation.brushScale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            context.setAlpha(MarkerAnnotation.markerAlpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            path.stroke()
            context.endTransparencyLayer()
            context.setAlpha(1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        // 形状预览。
        if let start = shapeStart, let rawCurrent = shapeCurrent {
            let current = constrainedShapeEnd(
                from: start,
                to: rawCurrent,
                tool: activeTool,
                modifiers: NSEvent.modifierFlags
            )
            context.setStrokeColor(currentColor.cgColor)
            context.setLineWidth(currentLineWidth)

            switch activeTool {
            case .rectangle:
                let rect = rectFromTwoPoints(start, current)
                RectAnnotation(
                    rect: rect,
                    color: currentColor,
                    lineWidth: currentLineWidth,
                    fillMode: currentShapeFillMode,
                    strokeStyle: currentShapeStrokeStyle,
                    roughStyle: previewRoughStyle(for: rect)
                ).draw(in: context, bounds: bounds)
            case .ellipse:
                let rect = rectFromTwoPoints(start, current)
                EllipseAnnotation(
                    rect: rect,
                    color: currentColor,
                    lineWidth: currentLineWidth,
                    fillMode: currentShapeFillMode,
                    strokeStyle: currentShapeStrokeStyle,
                    roughStyle: previewRoughStyle(for: rect)
                ).draw(in: context, bounds: bounds)
            case .mosaic:
                // 马赛克预览：半透明灰填充标记将被像素化的区域。
                let rect = rectFromTwoPoints(start, current)
                context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
                context.fill(rect)
            case .line:
                context.setLineCap(.round)
                context.move(to: start)
                context.addLine(to: current)
                context.strokePath()
            case .arrow:
                // 用 ArrowAnnotation 绘制预览，避免提交时可见跳变。
                ArrowAnnotation(
                    start: start,
                    end: current,
                    color: currentColor,
                    lineWidth: currentLineWidth,
                    style: currentArrowStyle
                ).draw(in: context, bounds: bounds)
            case .magnifier:
                let radius = hypot(current.x - start.x, current.y - start.y)
                if radius > 6, let baseImage = magnifierBaseImage {
                    MagnifierAnnotation(
                        center: start,
                        radius: radius,
                        color: currentColor,
                        lineWidth: currentLineWidth,
                        zoom: MagnifierAnnotation.defaultZoom,
                        sourceImage: baseImage
                    ).draw(in: context, bounds: bounds)
                }
            default:
                break
            }
        }

        // 橡皮擦框选。
        if let selection = eraserSelection {
            drawEraserSelection(rectFromTwoPoints(selection.start, selection.current), in: context)
        }

        // 编号工具预览（拖拽中徽章 + 箭头跟随光标）。
        if let pending = pendingNumberCreate {
            let tip: NSPoint? = (pending.current == pending.start) ? nil : pending.current
            NumberAnnotation(
                center: pending.start,
                number: document?.numberCounter ?? 1,
                color: currentColor,
                tip: tip
            ).draw(in: context, bounds: bounds)
        }

        // 文字气泡工具预览（仅气泡模式拖拽中）。
        if let pending = pendingTextCreate, currentTextCallout {
            TextAnnotation(
                text: "",
                origin: newTextOrigin(forClickAt: pending.start, fontSize: currentFontSize),
                color: currentColor,
                fontSize: currentFontSize,
                hasStroke: currentTextStroke,
                hasCallout: true,
                calloutTip: pending.current == pending.start ? nil : pending.current
            ).draw(in: context, bounds: bounds)
        }

        // emoji 工具光标处的半透明预览。
        if activeTool == .emoji, let currentEmoji, let emojiPreviewPoint {
            context.saveGState()
            context.setAlpha(0.45)
            EmojiAnnotation(emoji: currentEmoji, rect: emojiRect(centeredAt: emojiPreviewPoint))
                .draw(in: context, bounds: bounds)
            context.restoreGState()
        }
    }

    private func drawActiveTextCalloutBackground(in context: CGContext) {
        guard let field = activeTextField, field.hasCallout else { return }
        let fontSize = field.font?.pointSize ?? currentFontSize
        TextAnnotation(
            text: field.stringValue,
            origin: field.annotationOrigin,
            color: field.annotationColor,
            fontSize: fontSize,
            rotation: field.rotation,
            hasStroke: field.hasStroke,
            hasCallout: field.hasCallout,
            calloutTip: field.calloutTip
        ).drawCalloutBackgroundOnly(in: context, bodyRect: field.frame)
    }

    private func drawEraserSelection(_ rect: NSRect, in context: CGContext) {
        guard rect.width > 0 || rect.height > 0 else { return }
        context.saveGState()
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.13).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(3)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()
    }

    // MARK: - chrome 绘制

    /// hover 高亮：填充型标注（线/笔/箭头/编号/放大镜/未填充矩形椭圆）
    /// 重绘为 hover 色带阴影；其余画虚线框。参照 capcap L2344-2417。
    private func drawHoverHighlight(for annotation: Annotation, in context: CGContext) {
        if drawsHoverBody(for: annotation) {
            context.saveGState()
            context.setAlpha(0.96)
            context.setShadow(
                offset: .zero,
                blur: 5,
                color: AnnotationCanvasView.hoverColor.withAlphaComponent(0.45).cgColor
            )
            annotation
                .withColor(AnnotationCanvasView.hoverColor)
                .drawApplyingTransforms(in: context, bounds: bounds)
            context.restoreGState()
        } else {
            drawHoverFrame(for: annotation, in: context)
        }
    }

    private func drawsHoverBody(for annotation: Annotation) -> Bool {
        switch annotation {
        case let rect as RectAnnotation:
            return !rect.filled
        case let ellipse as EllipseAnnotation:
            return !ellipse.filled
        case is PenAnnotation,
             is MarkerAnnotation,
             is ArrowAnnotation,
             is LineAnnotation,
             is NumberAnnotation,
             is MagnifierAnnotation:
            return true
        default:
            return false
        }
    }

    private func drawHoverFrame(for annotation: Annotation, in context: CGContext) {
        let box = annotation.boundingRect.insetBy(
            dx: -AnnotationCanvasView.hoverBoxPad,
            dy: -AnnotationCanvasView.hoverBoxPad
        )
        guard box.width > 0, box.height > 0 else { return }
        let needsRotation = annotation.supportsRotation && annotation.rotation != 0
        context.saveGState()
        if needsRotation {
            let rect = annotation.boundingRect
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: annotation.rotation)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        let cornerRadius = min(7, max(3, min(box.width, box.height) * 0.18))
        let path = CGPath(
            roundedRect: box,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.setFillColor(AnnotationCanvasView.hoverColor.withAlphaComponent(0.10).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(AnnotationCanvasView.hoverColor.cgColor)
        context.setLineWidth(3)
        context.setLineJoin(.round)
        context.setShadow(
            offset: .zero,
            blur: 4,
            color: AnnotationCanvasView.hoverColor.withAlphaComponent(0.35).cgColor
        )
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSelectionOutline(for annotation: Annotation, in context: CGContext) {
        let box = selectionBox(for: annotation)
        let needsRotation = annotation.supportsRotation && annotation.rotation != 0
        context.saveGState()
        if needsRotation {
            let rect = annotation.boundingRect
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: annotation.rotation)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.setStrokeColor(AnnotationCanvasView.selectionOutlineColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(box)
        context.restoreGState()
    }

    /// 单选全套 chrome：虚线框 + resize handle + 旋转 handle + 曲线/tip/
    /// 气泡/源点/箭头端点 handle + delete/edit/步进按钮。参照 capcap L2436-2608。
    private func drawSelectionHandles(for annotation: Annotation, in context: CGContext) {
        drawSelectionOutline(for: annotation, in: context)

        // resize handle（可缩放类型）。
        if isResizable(annotation) {
            for anchor in ResizeAnchor.allCases {
                drawHandleDot(
                    at: resizeHandlePoint(anchor, for: annotation),
                    size: AnnotationCanvasView.resizeHandleSize,
                    fill: NSColor.white.withAlphaComponent(0.95),
                    stroke: AnnotationCanvasView.accentGreen,
                    in: context
                )
            }
        }

        // 旋转 handle + 虚线系绳。
        if annotation.supportsRotation {
            let handleCenter = rotationHandleCenter(for: annotation)
            let tether = rotationTetherAnchor(for: annotation)
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: tether)
            context.addLine(to: handleCenter)
            context.strokePath()
            context.restoreGState()

            drawHandleDot(
                at: handleCenter,
                size: AnnotationCanvasView.rotateHandleSize,
                fill: NSColor(white: 0.12, alpha: 0.94),
                stroke: AnnotationCanvasView.accentGreen,
                in: context
            )
            drawSymbolGlyph(
                "arrow.triangle.2.circlepath",
                at: handleCenter,
                pointSize: 10,
                in: context
            )
        }

        // 曲线 handle（箭头/编号）。
        if let cp = curveHandleCenter(for: annotation) {
            drawHandleDot(
                at: cp,
                size: AnnotationCanvasView.curveHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: AnnotationCanvasView.accentGreen,
                in: context
            )
        }
        // 编号徽章箭头尖 handle。
        if let tip = tipHandleCenter(for: annotation) {
            drawHandleDot(
                at: tip,
                size: AnnotationCanvasView.tipHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: AnnotationCanvasView.accentGreen,
                in: context
            )
        }
        // 文字气泡 handle（填充色用气泡色）。
        if let tip = textCalloutHandleCenter(for: annotation) {
            let fill = (annotation as? TextAnnotation)?.color ?? NSColor.white
            drawHandleDot(
                at: tip,
                size: AnnotationCanvasView.textCalloutHandleSize,
                fill: fill,
                stroke: NSColor.white.withAlphaComponent(0.95),
                in: context
            )
        }
        // 放大镜源点 handle。
        if let source = magnifierSourceHandleCenter(for: annotation) {
            drawHandleDot(
                at: source,
                size: AnnotationCanvasView.magnifierSourceHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: AnnotationCanvasView.accentGreen,
                in: context
            )
        }
        // 箭头/线端点 handle。
        if let start = arrowStartHandleCenter(for: annotation) {
            drawHandleDot(
                at: start,
                size: AnnotationCanvasView.endpointHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: AnnotationCanvasView.accentGreen,
                in: context
            )
        }
        if let end = arrowEndHandleCenter(for: annotation) {
            drawHandleDot(
                at: end,
                size: AnnotationCanvasView.endpointHandleSize,
                fill: NSColor.white.withAlphaComponent(0.95),
                stroke: AnnotationCanvasView.accentGreen,
                in: context
            )
        }

        // delete 按钮（始终）。
        drawActionButton(
            in: deleteButtonRect(for: annotation),
            symbolName: "xmark",
            symbolPointSize: 9,
            in: context
        )
        // edit 按钮（仅文字）。
        if let editRect = editButtonRect(for: annotation) {
            drawActionButton(
                in: editRect,
                symbolName: "pencil",
                symbolPointSize: 10,
                in: context
            )
        }
        // 编号步进按钮。
        if let number = annotation as? NumberAnnotation,
           let decRect = numberStepButtonRect(for: annotation, increment: false),
           let incRect = numberStepButtonRect(for: annotation, increment: true) {
            drawActionButton(
                in: decRect,
                symbolName: "minus",
                symbolPointSize: 9,
                enabled: number.number > 1,
                in: context
            )
            drawActionButton(
                in: incRect,
                symbolName: "plus",
                symbolPointSize: 9,
                in: context
            )
        }
        // 放大镜 zoom 步进按钮。
        if let magnifier = annotation as? MagnifierAnnotation,
           let decRect = magnifierZoomButtonRect(for: annotation, increment: false),
           let incRect = magnifierZoomButtonRect(for: annotation, increment: true) {
            drawActionButton(
                in: decRect,
                symbolName: "minus",
                symbolPointSize: 9,
                enabled: magnifier.zoom > MagnifierAnnotation.minZoom,
                in: context
            )
            drawActionButton(
                in: incRect,
                symbolName: "plus",
                symbolPointSize: 9,
                enabled: magnifier.zoom < MagnifierAnnotation.maxZoom,
                in: context
            )
        }
    }

    private func drawHandleDot(
        at center: NSPoint,
        size: CGFloat,
        fill: NSColor,
        stroke: NSColor,
        in context: CGContext
    ) {
        let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
    }

    /// 绘制白色着色的 SF Symbol（旋转/delete/edit 图标）。
    private func drawSymbolGlyph(
        _ symbolName: String,
        at center: NSPoint,
        pointSize: CGFloat,
        alpha: CGFloat = 1,
        in context: CGContext
    ) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard let img = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(cfg) else { return }

        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        let drawRect = NSRect(
            x: center.x - tinted.size.width / 2,
            y: center.y - tinted.size.height / 2,
            width: tinted.size.width,
            height: tinted.size.height
        )
        NSGraphicsContext.saveGraphicsState()
        tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: alpha)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 圆形深色按钮 + accent 圆环 + 中心 SF Symbol（delete/edit/步进）。
    private func drawActionButton(
        in rect: NSRect,
        symbolName: String,
        symbolPointSize: CGFloat,
        enabled: Bool = true,
        in context: CGContext
    ) {
        let alpha: CGFloat = enabled ? 1 : 0.4
        drawHandleDot(
            at: NSPoint(x: rect.midX, y: rect.midY),
            size: rect.width,
            fill: NSColor(white: 0.12, alpha: 0.94 * alpha),
            stroke: AnnotationCanvasView.accentGreen.withAlphaComponent(alpha),
            in: context
        )
        drawSymbolGlyph(
            symbolName,
            at: NSPoint(x: rect.midX, y: rect.midY),
            pointSize: symbolPointSize,
            alpha: alpha,
            in: context
        )
    }

    // MARK: - hover / 光标 / trackingArea

    private var canShowHoverHighlight: Bool {
        activeTextField == nil
            && activeTool != .eraser
            && dragState == nil
            && handleDragState == nil
            && eraserSelection == nil
            && currentPenPoints == nil
            && currentMarkerPoints == nil
            && shapeStart == nil
            && pendingNumberCreate == nil
            && pendingTextCreate == nil
    }

    private func setHoveredAnnotationIndex(_ index: Int?) {
        let total = document?.annotations.count ?? 0
        let resolved = index.flatMap { (0..<total).contains($0) ? $0 : nil }
        guard hoveredAnnotationIndex != resolved else { return }
        hoveredAnnotationIndex = resolved
        needsDisplay = true
    }

    private func updateHoverHighlight(at point: NSPoint) {
        guard canShowHoverHighlight, bounds.contains(point) else {
            setHoveredAnnotationIndex(nil)
            return
        }
        setHoveredAnnotationIndex(hitTestAnnotation(at: point))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverHighlight(at: point)
        updateEmojiPreview(at: point)
        updateCursor(at: point)
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoverHighlight(at: point)
        updateEmojiPreview(at: point)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredAnnotationIndex(nil)
        if emojiPreviewPoint != nil {
            emojiPreviewPoint = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    private func updateEmojiPreview(at point: NSPoint) {
        guard activeTool == .emoji, currentEmoji != nil else {
            if emojiPreviewPoint != nil {
                emojiPreviewPoint = nil
                needsDisplay = true
            }
            return
        }
        guard bounds.contains(point) else { return }
        if emojiPreviewPoint != point {
            emojiPreviewPoint = point
            needsDisplay = true
        }
    }

    /// 光标切换：文字编辑态让出 I-beam；橡皮擦/放大镜/emoji 专用光标；
    /// action 按钮 pointing hand；handle 拖拽方向光标/open hand；
    /// 可拖标注 open hand；无工具时空白 open hand（可拖选区）；其余 arrow。参照 capcap L3379-3428。
    private func updateCursor(at point: NSPoint) {
        if activeTextField != nil { return }
        if activeTool == .eraser {
            AnnotationCanvasView.eraserCursor.set()
            return
        }
        if hitTestSelectionAction(at: point) != nil {
            NSCursor.pointingHand.set()
            return
        }
        if let kind = hitTestSelectionHandle(at: point) {
            if case .resize(let anchor) = kind {
                AnnotationCanvasView.setResizeCursor(for: anchor)
            } else {
                NSCursor.openHand.set()
            }
            return
        }
        if hitTestAnnotation(at: point) != nil {
            NSCursor.openHand.set()
            return
        }
        if activeTool == .emoji, currentEmoji != nil {
            AnnotationCanvasView.plusCursor.set()
            return
        }
        if activeTool == .magnifier {
            AnnotationCanvasView.magnifierCursor.set()
            return
        }
        // 无工具时空白点击透传给 SelectionView 启动选区拖动 → openHand 提示可拖。
        if activeTool == .none {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func refreshCursorAtCurrentLocation() {
        guard let window else { return }
        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let local = convert(mouseInWindow, from: nil)
        guard bounds.contains(local) else {
            setHoveredAnnotationIndex(nil)
            return
        }
        updateHoverHighlight(at: local)
        updateCursor(at: local)
    }

    override func keyDown(with event: NSEvent) {
        if undoFromKeyboard(for: event) { return }
        if redoFromKeyboard(for: event) { return }
        if handleAnnotationClipboardShortcutFromKeyboard(for: event) { return }
        if nudgeSelectedAnnotationFromKeyboard(for: event) { return }
        if deleteSelectedAnnotationFromKeyboard(for: event) { return }
        super.keyDown(with: event)
    }

    // MARK: - 几何小工具

    private func appendStrokePoint(_ point: NSPoint, to buffer: inout [NSPoint]?) {
        guard buffer != nil else { return }
        if let last = buffer?.last, hypot(point.x - last.x, point.y - last.y) < 1.0 {
            return
        }
        buffer?.append(point)
    }

    private func rectFromTwoPoints(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private func previewRoughStyle(for rect: NSRect) -> RoughShapeStyle {
        RoughShapeStyle.make(
            seed: shapeRoughSeed ?? AnnotationCanvasView.fallbackShapePreviewSeed,
            rect: rect,
            lineWidth: currentLineWidth
        )
    }

    /// Shift 约束的形状终点。参照 capcap L2120-2139。
    private func constrainedShapeEnd(
        from start: NSPoint,
        to end: NSPoint,
        tool: EditTool,
        modifiers: NSEvent.ModifierFlags
    ) -> NSPoint {
        guard modifiers
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
        else { return end }
        switch tool {
        case .line, .arrow: return axisLockedEnd(from: start, to: end)
        case .rectangle, .ellipse: return squareLockedEnd(from: start, to: end)
        default: return end
        }
    }

    private func constrainsShapeWithShift(_ tool: EditTool) -> Bool {
        switch tool {
        case .line, .arrow, .rectangle, .ellipse: return true
        default: return false
        }
    }

    /// 水平/垂直线锁定：取 dx/dy 较大者方向。
    private func axisLockedEnd(from start: NSPoint, to end: NSPoint) -> NSPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dx) >= abs(dy) {
            return NSPoint(x: end.x, y: start.y)
        }
        return NSPoint(x: start.x, y: end.y)
    }

    /// 正方形/正圆锁定：取 dx/dy 较大者为边长，保留方向符号。
    private func squareLockedEnd(from start: NSPoint, to end: NSPoint) -> NSPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        guard side > 0 else { return end }
        let xSign: CGFloat = dx < 0 ? -1 : 1
        let ySign: CGFloat = dy < 0 ? -1 : 1
        return NSPoint(x: start.x + side * xSign, y: start.y + side * ySign)
    }

    // MARK: - 键盘事件判定

    private static func isUndoKey(_ event: NSEvent) -> Bool {
        commandShortcutCharacter(for: event) == "z"
    }

    private static func isRedoKey(_ event: NSEvent) -> Bool {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        // shift + z（无 command）视为 redo。
        return modifiers == [.shift] && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private static func commandShortcutCharacter(for event: NSEvent) -> String? {
        let activeModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let modifiers = event.modifierFlags.intersection(activeModifiers)
        guard modifiers == .command else { return nil }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    private static func isSelectionDeleteKey(_ event: NSEvent) -> Bool {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return event.keyCode == 51 || event.keyCode == 117
    }

    private static func selectionNudgeDelta(for event: NSEvent) -> NSPoint? {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(blockedModifiers).isEmpty else { return nil }
        let step: CGFloat = 1
        switch event.keyCode {
        case 123: return NSPoint(x: -step, y: 0)
        case 124: return NSPoint(x: step, y: 0)
        case 125: return NSPoint(x: 0, y: -step)
        case 126: return NSPoint(x: 0, y: step)
        default: return nil
        }
    }

    // MARK: - 光标图（参照 capcap L3206-3323）

    private static let magnifierCursor: NSCursor = {
        let size: CGFloat = 28
        let lensCenter = NSPoint(x: 11, y: 17)
        let lensRadius: CGFloat = 7
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let lens = NSBezierPath(ovalIn: NSRect(
                x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                width: lensRadius * 2, height: lensRadius * 2
            ))
            let diag = CGFloat(2).squareRoot() / 2
            let handleStart = NSPoint(x: lensCenter.x + lensRadius * diag, y: lensCenter.y - lensRadius * diag)
            let handle = NSBezierPath()
            handle.lineCapStyle = .round
            handle.move(to: handleStart)
            handle.line(to: NSPoint(x: handleStart.x + 7.5, y: handleStart.y - 7.5))
            let arm: CGFloat = 3.4
            let plus = NSBezierPath()
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: lensCenter.x - arm, y: lensCenter.y))
            plus.line(to: NSPoint(x: lensCenter.x + arm, y: lensCenter.y))
            plus.move(to: NSPoint(x: lensCenter.x, y: lensCenter.y - arm))
            plus.line(to: NSPoint(x: lensCenter.x, y: lensCenter.y + arm))
            NSColor.black.withAlphaComponent(0.55).setStroke()
            lens.lineWidth = 5; lens.stroke()
            handle.lineWidth = 7; handle.stroke()
            plus.lineWidth = 4; plus.stroke()
            NSColor.white.setStroke()
            lens.lineWidth = 2; lens.stroke()
            handle.lineWidth = 3.5; handle.stroke()
            plus.lineWidth = 1.8; plus.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: lensCenter.x, y: size - lensCenter.y))
    }()

    private static let eraserCursor: NSCursor = {
        let size: CGFloat = 28
        let center = NSPoint(x: 14, y: 14)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: -35)
            transform.translateX(by: -center.x, yBy: -center.y)
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
            let bodyRect = NSRect(x: 7, y: 9, width: 16, height: 10)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)
            NSColor.black.withAlphaComponent(0.55).setStroke()
            body.lineWidth = 5
            body.stroke()
            NSColor.white.setFill()
            body.fill()
            NSColor.systemRed.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: NSRect(x: 7, y: 9, width: 7, height: 10), xRadius: 3, yRadius: 3).fill()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 14, y: 10))
            divider.line(to: NSPoint(x: 14, y: 18))
            NSColor.black.withAlphaComponent(0.28).setStroke()
            divider.lineWidth = 1
            divider.stroke()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            body.lineWidth = 1.5
            body.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: center.x, y: size - center.y))
    }()

    private static let plusCursor: NSCursor = {
        let size: CGFloat = 28
        let center = NSPoint(x: 14, y: 14)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let plus = NSBezierPath()
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: center.x - 8, y: center.y))
            plus.line(to: NSPoint(x: center.x + 8, y: center.y))
            plus.move(to: NSPoint(x: center.x, y: center.y - 8))
            plus.line(to: NSPoint(x: center.x, y: center.y + 8))
            NSColor.black.withAlphaComponent(0.55).setStroke()
            plus.lineWidth = 5
            plus.stroke()
            NSColor.white.setStroke()
            plus.lineWidth = 2.5
            plus.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: center.x, y: size - center.y))
    }()

    /// 按 resize 锚点设置方向光标。
    private static func setResizeCursor(for anchor: ResizeAnchor) {
        switch anchor {
        case .topLeft, .bottomRight:
            NSCursor.crosshair.set()
        case .topRight, .bottomLeft:
            NSCursor.crosshair.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .left, .right:
            NSCursor.resizeLeftRight.set()
        }
    }
}
