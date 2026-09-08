import AppKit
import ApplicationServices
import Foundation
import os.log
import QuartzCore

// 注：`EditTool` 枚举位于 `AnnotationCanvasView.swift`（画布交互层），
// 由控制器与画布共用。

/// 标注编辑器控制器 —— 嵌入 overlay 窗口 SelectionView 的非窗口控制器。
///
/// 重构为 capcap 式编排（`EditWindowController`）：
/// - 不再持有独立 `NSWindow`，而是把 canvas + 工具栏作为子视图注入
///   `hostSelectionView`（与选区共享 overlay 窗口）。
/// - 接阶段 2 画布的四个回调：onAnnotationSelected（回填样式+切工具+重建
///   子工具栏）、onMultiSelectionChanged、onHistoryStateChanged（刷新
///   undo/redo 按钮态）、onEmojiStamped。
/// - 工具切换链路：selectTool → canvasView.activeTool + pushCurrentStyleToCanvas
///   + showSubToolbar（参照 capcap L407-462, 538-718）。
/// - 输出动作：confirm(复制)/save/pin 经 `ScreenshotResultRunning` 统一副作用；
///   编辑器负责合成图、`makeResult` 构造 `ScreenshotResult`、成功/失败 UI。
///   - confirm：composite → makeResult → `run(.copy)`；失败保留 UI，成功 onComplete(image)。
///   - save：先 tearDown，再 `run(.save)`；失败仍呈现错误并 onComplete(nil)。
///   - pin：composite → makeResult → `run(.pin, pinOrigin:)`；失败保留 UI。
///   错误反馈用 NSAlert（capcap 用 ToastWindow，OmniForge 暂用 NSAlert）。
///   长截图裁切直出仍暂走 encoder/clipboard（不在本期 pipeline 迁入范围）。
@MainActor
final class AnnotationEditorController {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "ScreenshotEditor")

    /// 当前编辑底图；选区变更时可由 `updateLayout` 替换为重裁切结果。
    private var baseImage: NSImage
    private let document: AnnotationDocument
    private let stringsProvider: () -> Strings
    private let onComplete: (NSImage?) -> Void

    /// 捕获上下文：预抓快照与当前 captureRect（CG 全局坐标），供选区变更重裁切。
    private(set) var preSnapshot: CGImage?
    private(set) var captureRect: CGRect = .zero
    private(set) var sourceDisplayID: CGDirectDisplayID?
    /// 源屏引用：draw 时现裁底图所需（对齐 CapCap `captureScreen`）。
    private(set) var screen: NSScreen?

    /// 统一 copy/save/pin 副作用出口（生产为共享 `ScreenshotResultPipeline`）。
    private let resultRunner: ScreenshotResultRunning
    /// 长截图裁切直出仍用 encoder/clipboard（非 confirm/save/pin 路径）。
    private let encoder: ImageOutputEncoding
    private let clipboardWriter: ClipboardImageWriting
    /// 由 overlay/factory 注入：合成图 → `ScreenshotResult`（含目标屏上下文）；
    /// confirm / save / pin 共用，避免三处构造分歧。
    private let makeResult: (NSImage) -> ScreenshotResult?

    /// 截图源屏的点→像素比例。合成图必须按此密度建位图，否则多屏 backingScaleFactor
    /// 不一致时（如主屏 2×、副屏 1×）钉住显示尺寸会被放大/缩小（参见 compositeImage）。
    /// 必须与 pin 的 `pointPixelScale` 同源，二者自洽即可保证钉住尺寸正确。
    private let sourceBackingScaleFactor: CGFloat

    /// 选区录屏回调：参数为 AppKit screen rect + 目标屏。
    /// 由 overlay/manager 注入；为 nil 时工具栏 record 不响应。
    var onRecordingSelection: ((NSRect, NSScreen) -> Void)?

    /// 最近一次输出错误（供测试与外部观察；阶段 6 可换 Toast 展示）。
    private(set) var lastError: Error?

    private weak var hostSelectionView: SelectionView?
    private(set) var canvasView: AnnotationCanvasView?
    private var canvasScrollView: EditorScrollView?
    private var selectionChromeOverlay: SelectionChromeOverlay?
    private var toolbarView: AnnotationToolbarView?
    private var subToolbarView: NSView?

    private(set) var activeTool: EditTool = .none
    /// 移动模式：无标注工具，选区内按住拖动即移动选区（工具栏手柄点击切换）。
    private var isMoveModeActive = false

    // MARK: - 长截图状态

    private var isScrollCapturing = false
    private var isScrollCaptureFinalizing = false
    private var scrollCapturer: ScrollCapturer?
    private var scrollCaptureHUDWindow: ScrollCaptureHUDWindow?
    private var scrollPreviewWindow: ScrollPreviewWindow?
    private var infoToastWindow: EditorInfoToastWindow?
    private var scrollCaptureKeyMonitor: Any?

    private var isScrollCaptureBusy: Bool { isScrollCapturing || isScrollCaptureFinalizing }

    /// 活屏会话且有预抓快照；长截图完成后（preview 已加载）禁止再次滚动捕获。
    private var isScrollCaptureAllowed: Bool {
        canvasView?.hasPreviewImage != true && preSnapshot != nil && captureRect.width > 0 && captureRect.height > 0
    }

    // 当前绘制样式槽位（参照 capcap L133-156）
    private var currentColor: NSColor = EditorStyleDefaults.primaryColor
    private var currentLineWidth: CGFloat = EditorStyleDefaults.standardLineWidth
    private var currentArrowStyle: ArrowStyle = .tapered
    private var currentMosaicBlockSize: CGFloat = EditorStyleDefaults.mosaicBlockSize
    private var currentFontSize: CGFloat = EditorStyleDefaults.fontSize
    private var currentTextStroke: Bool = false
    private var currentTextCallout: Bool = false
    private var currentShapeFillMode: ShapeFillMode = .none
    private var currentShapeStrokeStyle: ShapeStrokeStyle = .standard
    private var currentMarkerColor: NSColor = EditorStyleDefaults.markerColor
    private var currentMarkerLineWidth: CGFloat = EditorStyleDefaults.markerLineWidth
    private var currentEmoji: String?
    private var emojiPopover: NSPopover?
    private var recentEmojis: [String] = Defaults.recentEmojis()

    /// 美化开关与预设（参照 capcap）。启用时 compositeImage 末尾应用
    /// BeautifyRenderer.render（背景 + 圆角 + 双层阴影 + padding）。
    private var beautifyEnabled: Bool = false
    private var beautifyPreset: BeautifyPreset = .defaultPreset
    /// 美化壁纸位图（wallpaper 预设时异步加载）。
    private var beautifyWallpaper: NSImage?

    /// 编辑器嵌入区域（选区视图坐标）。
    private var selectionViewRect: NSRect

    /// 测试钩子：当前选区视图矩形。
    var selectionViewRectForTesting: NSRect { selectionViewRect }
    /// 测试钩子：当前编辑器使用的字符串目录。
    var stringsForTesting: Strings { stringsProvider() }

    private var keyMonitor: Any?

    // MARK: - 初始化

    init(baseImage: NSImage,
         document: AnnotationDocument,
         stringsProvider: @escaping () -> Strings = { .en },
         resultRunner: ScreenshotResultRunning,
         encoder: ImageOutputEncoding = ImageOutputEncoder(),
         clipboardWriter: ClipboardImageWriting = ClipboardImageWriter(),
         makeResult: @escaping (NSImage) -> ScreenshotResult? = { _ in nil },
         sourceBackingScaleFactor: CGFloat = NSScreen.main?.backingScaleFactor ?? 1,
         onComplete: @escaping (NSImage?) -> Void) {
        self.baseImage = baseImage
        self.document = document
        self.stringsProvider = stringsProvider
        self.resultRunner = resultRunner
        self.encoder = encoder
        self.clipboardWriter = clipboardWriter
        self.makeResult = makeResult
        // 合法性夹取：< 1 或非有限时回退 1（与无屏环境一致）。
        self.sourceBackingScaleFactor = (sourceBackingScaleFactor >= 1 && sourceBackingScaleFactor.isFinite)
            ? sourceBackingScaleFactor
            : 1
        self.onComplete = onComplete
        self.selectionViewRect = NSRect(origin: .zero, size: baseImage.size)
    }

    /// 兼容旧调用：未注入 pipeline 时用默认 `ScreenshotResultPipeline`（无 pinService）。
    /// 测试/生产应优先显式注入共享 pipeline。
    convenience init(
        baseImage: NSImage,
        document: AnnotationDocument,
        stringsProvider: @escaping () -> Strings = { .en },
        encoder: ImageOutputEncoding = ImageOutputEncoder(),
        clipboardWriter: ClipboardImageWriting = ClipboardImageWriter(),
        saver: ScreenshotSaving = ScreenshotSaver(),
        outputConfigurationProvider: @escaping () -> ScreenshotOutputConfigurationSnapshot = {
            ScreenshotOutputConfiguration().load()
        },
        pinService: ScreenshotPinning? = nil,
        pinResultBuilder: @escaping (NSImage) -> ScreenshotResult? = { _ in nil },
        sourceBackingScaleFactor: CGFloat = NSScreen.main?.backingScaleFactor ?? 1,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        let pipeline = ScreenshotResultPipeline(
            encoder: encoder,
            clipboardWriter: clipboardWriter,
            saver: saver,
            outputConfigurationProvider: outputConfigurationProvider
        )
        pipeline.pinService = pinService
        self.init(
            baseImage: baseImage,
            document: document,
            stringsProvider: stringsProvider,
            resultRunner: pipeline,
            encoder: encoder,
            clipboardWriter: clipboardWriter,
            makeResult: pinResultBuilder,
            sourceBackingScaleFactor: sourceBackingScaleFactor,
            onComplete: onComplete
        )
    }

    // MARK: - 展示

    /// 在选区视图内嵌入编辑器。参照 capcap `EditWindowController.show`。
    /// - Parameters:
    ///   - captureRect: 选区对应的 CG 全局坐标矩形（重裁切用）。
    ///   - preSnapshot: 预抓整屏快照；二次选区从中重裁切底图。
    ///   - displayID: 源屏 displayID。
    func show(
        in hostSelectionView: SelectionView,
        selectionRect: NSRect,
        captureRect: CGRect = .zero,
        preSnapshot: CGImage? = nil,
        displayID: CGDirectDisplayID? = nil
    ) {
        self.hostSelectionView = hostSelectionView
        self.selectionViewRect = selectionRect
        self.captureRect = captureRect
        self.preSnapshot = preSnapshot
        self.sourceDisplayID = displayID
        self.screen = hostSelectionView.window?.screen

        let canvasSize = selectionRect.size

        // 画布
        let canvas = AnnotationCanvasView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.baseImage = baseImage
        canvas.captureRect = captureRect
        canvas.preSnapshot = preSnapshot
        canvas.sourceDisplayID = displayID
        canvas.captureScreen = self.screen
        canvas.controller = self
        canvas.document = document
        canvas.autoresizingMask = []
        canvas.onAnnotationSelected = { [weak self] annotation in
            self?.handleAnnotationSelectionChanged(annotation)
        }
        canvas.onMultiSelectionChanged = { [weak self] isMultiSelecting in
            if isMultiSelecting {
                self?.selectTool(.none)
            }
        }
        canvas.onHistoryStateChanged = { [weak self] canUndo, canRedo in
            self?.updateHistoryButtons(canUndo: canUndo, canRedo: canRedo)
        }
        canvas.onEmojiStamped = { [weak self] in
            self?.handleEmojiStamped()
        }
        self.canvasView = canvas

        // 滚动视图（选区大时纵向滚动）；透传 hitTest 见 EditorScrollView。
        let scrollView = EditorScrollView(frame: selectionRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = canvasSize.height > selectionRect.height + 0.5
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = canvas
        scrollView.editorCanvasView = canvas
        scrollView.automaticallyAdjustsContentInsets = false
        hostSelectionView.addSubview(scrollView)
        self.canvasScrollView = scrollView

        // 选区 chrome 叠在 scrollView 之上：仅 handle 命中，空白透传。
        let overlay = SelectionChromeOverlay(frame: hostSelectionView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.selectionView = hostSelectionView
        hostSelectionView.addSubview(overlay)
        self.selectionChromeOverlay = overlay

        // 工具栏
        showToolbar()
        updateHistoryButtons(canUndo: document.canUndo, canRedo: document.canRedo)

        // 默认无标注工具：空白拖动不移动选区，移动仅靠工具栏手柄。
        updateEditorInteractionState()
        bringEditorToFront()
        installKeyboardShortcuts()
    }

    /// 选区移动/缩放后重排编辑器布局（不重建控制器、不清空标注）。
    /// 参照 capcap `EditWindowController.updateLayout`：只更新 `captureRect`，
    /// 不替换底图数据；底图由 canvas 在 draw 时按 `captureRect` 从 `preSnapshot` 现裁。
    func updateLayout(selectionViewRect: NSRect, captureRect: CGRect) {
        self.selectionViewRect = selectionViewRect
        self.captureRect = captureRect
        canvasView?.captureRect = captureRect
        canvasView?.captureScreen = screen

        canvasScrollView?.frame = selectionViewRect
        if canvasView?.hasPreviewImage != true {
            // 无长截图预览时 canvas 尺寸 = 选区尺寸。
            canvasView?.setFrameSize(selectionViewRect.size)
            canvasScrollView?.hasVerticalScroller = false
        }

        repositionToolbars()
        selectionChromeOverlay?.update(
            rect: selectionViewRect,
            active: hostSelectionView?.selectionInteractionEnabled == true
        )
        updateEditorInteractionState()
        canvasView?.needsDisplay = true
    }

    /// 按当前 `selectionViewRect` 重放主/子工具栏位置。
    private func repositionToolbars() {
        guard let host = hostSelectionView else { return }
        if let primary = toolbarView {
            primary.frame = toolbarRect(in: host.bounds, size: primary.preferredSize)
        }
        if let sub = subToolbarView, let anchor = subToolbarAnchorFrame {
            sub.frame = subToolbarRect(
                width: sub.frame.width,
                height: sub.frame.height,
                toolbarFrame: anchor,
                in: host.bounds
            )
        }
    }

    // MARK: - 工具栏

    private func showToolbar() {
        guard let host = hostSelectionView else { return }

        let primary = AnnotationToolbarView(
            items: AnnotationToolbarLayout.primary,
            orientation: .horizontal,
            stringsProvider: stringsProvider
        )
        wireToolbar(primary)
        primary.frame = toolbarRect(in: host.bounds, size: primary.preferredSize)
        styleFloatingHUD(primary)
        host.addSubview(primary)
        toolbarView = primary
    }

    private func wireToolbar(_ tv: AnnotationToolbarView) {
        tv.onToolSelected = { [weak self] tool in self?.selectTool(tool) }
        tv.onMoveSelectionToggle = { [weak self] in self?.toggleMoveMode() }
        tv.onUndo = { [weak self] in _ = self?.document.undo(); self?.canvasView?.needsDisplay = true }
        tv.onRedo = { [weak self] in _ = self?.document.redo(); self?.canvasView?.needsDisplay = true }
        tv.onSave = { [weak self] in self?.save() }
        tv.onPin = { [weak self] in self?.pin() }
        tv.onClose = { [weak self] in self?.close() }
        tv.onConfirm = { [weak self] in self?.confirm() }
        tv.onMoveSelectionStart = { [weak self] in self?.handleMoveSelectionStart() }
        tv.onMoveSelectionDrag = { [weak self] delta in self?.handleMoveSelectionDrag(delta: delta) }
        tv.onMoveSelectionEnd = { [weak self] in self?.handleMoveSelectionEnd() }
        tv.onScrollCapture = { [weak self] in self?.toggleScrollCapture() }
        tv.onRecord = { [weak self] in self?.record() }
        refreshScrollCaptureAvailability()
    }

    // MARK: - 录屏

    /// 结束编辑器并回调选区的 AppKit 屏幕坐标，供录屏会话使用。
    /// 顺序：提交文本 → 取 screen rect → tearDown → onComplete(nil) → 回调。
    private func record() {
        guard let onRecordingSelection,
              let host = hostSelectionView,
              let window = host.window,
              let screen = window.screen else { return }
        canvasView?.commitActiveTextEditing()
        let windowRect = host.convert(selectionViewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let callback = onRecordingSelection
        tearDown()
        onComplete(nil)
        callback(screenRect, screen)
    }

    // MARK: - 移动选区手柄

    private var moveSelectionStartRect: NSRect = .zero

    private func handleMoveSelectionStart() {
        canvasView?.commitActiveTextEditing()
        moveSelectionStartRect = hostSelectionView?.currentSelectionRect ?? selectionViewRect
    }

    private func handleMoveSelectionDrag(delta: CGSize) {
        hostSelectionView?.moveByExternalDrag(
            deltaFromOriginal: delta,
            originalRect: moveSelectionStartRect
        )
        if let rect = hostSelectionView?.currentSelectionRect {
            selectionViewRect = rect
            selectionChromeOverlay?.update(
                rect: rect,
                active: hostSelectionView?.selectionInteractionEnabled == true
            )
        }
    }

    private func handleMoveSelectionEnd() {
        hostSelectionView?.finalizeExternalDrag()
        if let rect = hostSelectionView?.currentSelectionRect {
            selectionViewRect = rect
        }
        moveSelectionStartRect = .zero
        updateEditorInteractionState()
    }

    private var toolbars: [AnnotationToolbarView] {
        [toolbarView].compactMap { $0 }
    }

    private var subToolbarAnchorFrame: NSRect? {
        toolbarView?.frame
    }

    private func updateHistoryButtons(canUndo: Bool, canRedo: Bool) {
        toolbars.forEach {
            $0.setUndoEnabled(canUndo)
            $0.setRedoEnabled(canRedo)
        }
    }

    // MARK: - 工具切换

    /// 切换工具：提交文字 → 清多选 → 推样式 → 刷工具栏 → 子工具栏。
    /// 参照 capcap L407-427。
    func selectTool(_ tool: EditTool) {
        if tool != .none {
            canvasView?.clearMultiSelection()
        }
        activeTool = tool
        canvasView?.activeTool = tool
        if tool != .none {
            isMoveModeActive = false
        }
        normalizeShapeStrokeStyle(for: tool)
        pushCurrentStyleToCanvas()
        toolbars.forEach { $0.updateSelection(tool: tool) }
        toolbars.forEach { $0.setMoveModeActive(isMoveModeActive && tool == .none) }
        showSubToolbar(for: tool)
        updateEditorInteractionState()
        bringEditorToFront()
    }

    /// 点击工具栏移动手柄：进入/退出移动模式。
    /// 进入时切到无工具态（选区内部拖动即移动选区），再次点击退出。
    private func toggleMoveMode() {
        isMoveModeActive.toggle()
        if isMoveModeActive && activeTool != .none {
            selectTool(.none)
            return
        }
        toolbars.forEach { $0.setMoveModeActive(isMoveModeActive) }
    }

    /// 同步选区交互标志、scroll 透传与 chrome 显隐（对齐 CapCap）。
    private func updateEditorInteractionState() {
        let hasPreview = canvasView?.hasPreviewImage == true
        let isBlocked = isScrollCaptureBusy
        hostSelectionView?.annotationToolActive = !isBlocked
        // 长截图 preview 后禁止再移动/缩放选区。
        hostSelectionView?.selectionInteractionEnabled = !(isBlocked || hasPreview)
        canvasScrollView?.isInteractionEnabled = (activeTool != .none) || hasPreview
        selectionChromeOverlay?.update(
            rect: selectionViewRect,
            active: hostSelectionView?.selectionInteractionEnabled == true
        )
        hostSelectionView?.needsDisplay = true
        refreshScrollCaptureAvailability()
    }

    private func refreshScrollCaptureAvailability() {
        let enabled = isScrollCaptureAllowed && !isScrollCaptureBusy && canvasView?.hasPreviewImage != true
        toolbars.forEach { $0.setScrollCaptureEnabled(enabled) }
    }

    private func normalizeShapeStrokeStyle(for tool: EditTool) {
        guard tool == .ellipse, currentShapeStrokeStyle == .rounded else { return }
        currentShapeStrokeStyle = .standard
    }

    /// 把当前样式槽位同步到画布。参照 capcap L449-462。
    private func pushCurrentStyleToCanvas() {
        guard let canvas = canvasView else { return }
        canvas.currentColor = currentColor
        canvas.currentLineWidth = currentLineWidth
        canvas.currentArrowStyle = currentArrowStyle
        canvas.currentMosaicBlockSize = currentMosaicBlockSize
        canvas.currentFontSize = currentFontSize
        canvas.currentTextStroke = currentTextStroke
        canvas.currentTextCallout = currentTextCallout
        canvas.currentShapeFillMode = currentShapeFillMode
        canvas.currentShapeStrokeStyle = currentShapeStrokeStyle
        canvas.currentEmoji = currentEmoji
        canvas.currentMarkerColor = currentMarkerColor
        canvas.currentMarkerLineWidth = currentMarkerLineWidth
    }

    // MARK: - 选中回填

    /// 选中标注变化时，按其样式种子化当前槽位并切换工具/重建子工具栏。
    /// 参照 capcap `handleAnnotationSelectionChanged`（L433-447）。
    private func handleAnnotationSelectionChanged(_ annotation: Annotation?) {
        guard let annotation else { return }
        guard let tool = tool(for: annotation), tool != .none else { return }
        seedCurrentValues(from: annotation)
        pushCurrentStyleToCanvas()
        if activeTool != tool {
            selectTool(tool)
        } else {
            showSubToolbar(for: tool)
        }
    }

    private func tool(for annotation: Annotation) -> EditTool? {
        switch annotation {
        case is TextAnnotation: return .text
        case is RectAnnotation: return .rectangle
        case is EllipseAnnotation: return .ellipse
        case is ArrowAnnotation: return .arrow
        case is LineAnnotation: return .line
        case is PenAnnotation: return .pen
        case is MarkerAnnotation: return .marker
        case is MosaicAnnotation: return .mosaic
        case is MagnifierAnnotation: return .magnifier
        case is NumberAnnotation: return .number
        case is EmojiAnnotation: return .emoji
        default: return nil
        }
    }

    /// 从选中标注回填样式槽位。参照 capcap `seedCurrentValues`（L484-531）。
    private func seedCurrentValues(from annotation: Annotation) {
        switch annotation {
        case let t as TextAnnotation:
            currentColor = t.color
            currentFontSize = t.fontSize
            currentTextStroke = t.hasStroke
            currentTextCallout = t.hasCallout
        case let p as PenAnnotation:
            currentColor = p.color
            currentLineWidth = p.lineWidth
        case let m as MarkerAnnotation:
            currentMarkerColor = m.color
            currentMarkerLineWidth = m.lineWidth
        case let mosaic as MosaicAnnotation:
            currentMosaicBlockSize = mosaic.blockSize
            canvasView?.currentMosaicBlockSize = mosaic.blockSize
        case let magnifier as MagnifierAnnotation:
            currentColor = magnifier.color
            currentLineWidth = magnifier.lineWidth
        case let r as RectAnnotation:
            currentColor = r.color
            currentLineWidth = r.lineWidth
            currentShapeFillMode = r.fillMode
            currentShapeStrokeStyle = r.strokeStyle
        case let e as EllipseAnnotation:
            currentColor = e.color
            currentLineWidth = e.lineWidth
            currentShapeFillMode = e.fillMode
            currentShapeStrokeStyle = e.strokeStyle == .rounded ? .standard : e.strokeStyle
        case let a as ArrowAnnotation:
            currentColor = a.color
            currentLineWidth = a.lineWidth
            currentArrowStyle = a.style
        case let l as LineAnnotation:
            currentColor = l.color
            currentLineWidth = l.lineWidth
        case let n as NumberAnnotation:
            currentColor = n.color
        case is EmojiAnnotation:
            currentEmoji = nil
            canvasView?.currentEmoji = nil
        default:
            break
        }
    }

    // MARK: - 子工具栏

    private func showSubToolbar(for tool: EditTool) {
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil

        switch tool {
        case .pen, .line:
            installColorSizeSubToolbar(sizes: EditorStyleDefaults.standardLineSizes,
                                       onColor: { [weak self] c in self?.setCurrentDrawingColor(c) },
                                       onSize: { [weak self] size in self?.setCurrentDrawingLineWidth(size) })
        case .arrow:
            installColorSizeSubToolbar(
                sizes: EditorStyleDefaults.standardLineSizes,
                arrowStyle: currentArrowStyle,
                onColor: { [weak self] c in self?.setCurrentDrawingColor(c) },
                onSize: { [weak self] size in self?.setCurrentDrawingLineWidth(size) },
                onArrowStyle: { [weak self] style in self?.setArrowStyle(style) }
            )
        case .rectangle, .ellipse:
            installColorSizeSubToolbar(
                sizes: EditorStyleDefaults.standardLineSizes,
                shapeFillMode: currentShapeFillMode,
                shapeStrokeStyle: currentShapeStrokeStyle,
                onColor: { [weak self] c in self?.setCurrentDrawingColor(c) },
                onSize: { [weak self] size in self?.setCurrentDrawingLineWidth(size) },
                onShapeFillMode: { [weak self] mode in self?.setShapeFillMode(mode) },
                onShapeStrokeStyle: { [weak self] style in self?.setShapeStrokeStyle(style) }
            )
        case .marker:
            installColorSizeSubToolbar(sizes: EditorStyleDefaults.markerLineSizes,
                                       initialColor: currentMarkerColor,
                                       initialSize: currentMarkerLineWidth,
                                       isMarker: true,
                                       onColor: { [weak self] c in self?.setCurrentMarkerColor(c) },
                                       onSize: { [weak self] size in self?.setCurrentMarkerLineWidth(size) })
        case .number:
            installColorSizeSubToolbar(sizes: [],
                                       initialColor: currentColor,
                                       onColor: { [weak self] c in self?.setCurrentDrawingColor(c) })
        case .mosaic:
            installMosaicSubToolbar()
        case .text:
            installTextSubToolbar()
        case .emoji:
            showEmojiPopover()
        case .none, .eraser, .magnifier, .image:
            break
        }
    }

    private func installColorSizeSubToolbar(
        sizes: [CGFloat],
        initialColor: NSColor? = nil,
        initialSize: CGFloat? = nil,
        isMarker: Bool = false,
        arrowStyle: ArrowStyle? = nil,
        shapeFillMode: ShapeFillMode? = nil,
        shapeStrokeStyle: ShapeStrokeStyle? = nil,
        onColor: ((NSColor) -> Void)? = nil,
        onSize: ((CGFloat) -> Void)? = nil,
        onArrowStyle: ((ArrowStyle) -> Void)? = nil,
        onShapeFillMode: ((ShapeFillMode) -> Void)? = nil,
        onShapeStrokeStyle: ((ShapeStrokeStyle) -> Void)? = nil
    ) {
        guard let host = hostSelectionView else { return }
        let color = initialColor ?? currentColor
        let size = initialSize ?? currentLineWidth

        let width = ColorSizeSubToolbar.preferredWidth(
            sizes: sizes,
            dynamicColor: nil,
            showsArrowStyle: arrowStyle != nil,
            showsShapeFill: shapeFillMode != nil,
            showsShapeStroke: shapeStrokeStyle != nil
        )
        // 滑块范围：荧光笔走荧光笔线宽范围，其余走标准线宽范围。
        let sizeMin = isMarker ? EditorStyleDefaults.markerLineWidthMin
                               : EditorStyleDefaults.standardLineWidthMin
        let sizeMax = isMarker ? EditorStyleDefaults.markerLineWidthMax
                               : EditorStyleDefaults.standardLineWidthMax
        let frame = NSRect(x: 0, y: 0, width: width, height: 44)
        let sub = ColorSizeSubToolbar(
            frame: frame,
            sizes: sizes,
            currentColor: color,
            currentSize: size,
            sizeMin: sizeMin,
            sizeMax: sizeMax,
            arrowStyle: arrowStyle,
            shapeFillMode: shapeFillMode,
            shapeStrokeStyle: shapeStrokeStyle
        )
        sub.onColorChanged = { c in
            onColor?(c)
        }
        sub.onSizeBegan = { [weak self] in self?.canvasView?.beginSelectionAdjustment() }
        sub.onSizeChanged = { size in onSize?(size) }
        sub.onSizeEnded = { [weak self] in self?.canvasView?.commitSelectionAdjustment() }
        sub.onArrowStyleChanged = { style in onArrowStyle?(style) }
        sub.onShapeFillModeChanged = { mode in onShapeFillMode?(mode) }
        sub.onShapeStrokeStyleChanged = { style in onShapeStrokeStyle?(style) }
        placeSubToolbar(sub, in: host)
        subToolbarView = sub
    }

    private func installMosaicSubToolbar() {
        guard let host = hostSelectionView else { return }
        let frame = NSRect(x: 0, y: 0, width: MosaicSubToolbar.preferredWidth, height: 44)
        let sub = MosaicSubToolbar(frame: frame, currentBlockSize: currentMosaicBlockSize)
        sub.onBlockSizeBegan = { [weak self] in self?.canvasView?.beginSelectionAdjustment() }
        sub.onBlockSizeChanged = { [weak self] size in
            self?.currentMosaicBlockSize = size
            self?.canvasView?.currentMosaicBlockSize = size
            self?.canvasView?.mutateSelectedMosaicBlockSizeLive(size)
        }
        sub.onBlockSizeEnded = { [weak self] in self?.canvasView?.commitSelectionAdjustment() }
        placeSubToolbar(sub, in: host)
        subToolbarView = sub
    }

    private func installTextSubToolbar() {
        guard let host = hostSelectionView else { return }
        let strings = stringsProvider()
        let width = TextSubToolbar.preferredWidth(
            strokeLabel: strings.annotationTextOutline,
            calloutLabel: strings.annotationTextFill
        )
        let frame = NSRect(x: 0, y: 0, width: width, height: 44)
        let sub = TextSubToolbar(
            frame: frame,
            currentColor: currentColor,
            currentFontSize: currentFontSize,
            strokeEnabled: currentTextStroke,
            calloutEnabled: currentTextCallout,
            strokeLabel: strings.annotationTextOutline,
            calloutLabel: strings.annotationTextFill
        )
        sub.onColorChanged = { [weak self] c in self?.setCurrentDrawingColor(c) }
        sub.onFontSizeBegan = { [weak self] in self?.canvasView?.beginSelectionAdjustment() }
        sub.onFontSizeChanged = { [weak self] size in self?.setCurrentFontSize(size) }
        sub.onFontSizeEnded = { [weak self] in self?.canvasView?.commitSelectionAdjustment() }
        sub.onStrokeChanged = { [weak self] on in self?.setCurrentTextStroke(on) }
        sub.onCalloutChanged = { [weak self] on in self?.setCurrentTextCallout(on) }
        placeSubToolbar(sub, in: host)
        subToolbarView = sub
    }

    private func placeSubToolbar(_ sub: NSView, in host: NSView) {
        host.addSubview(sub)
        guard let anchor = subToolbarAnchorFrame else { return }
        let rect = subToolbarRect(
            width: sub.frame.width,
            height: sub.frame.height,
            toolbarFrame: anchor,
            in: host.bounds
        )
        sub.frame = rect
        styleFloatingHUD(sub)
    }

    // MARK: - 样式设置器（参照 capcap L1907-1985）

    private func setCurrentDrawingColor(_ color: NSColor) {
        currentColor = color
        canvasView?.currentColor = color
        canvasView?.mutateSelectedAnnotationAtomic { $0.withColor(color) }
    }

    private func setCurrentDrawingLineWidth(_ size: CGFloat) {
        currentLineWidth = size
        canvasView?.currentLineWidth = size
        canvasView?.mutateSelectedAnnotationAtomic { $0.withLineWidth(size) }
    }

    private func setCurrentMarkerColor(_ color: NSColor) {
        currentMarkerColor = color
        canvasView?.currentMarkerColor = color
    }

    private func setCurrentMarkerLineWidth(_ size: CGFloat) {
        let clamped = min(max(size, EditorStyleDefaults.markerLineWidthMin),
                          EditorStyleDefaults.markerLineWidthMax)
        currentMarkerLineWidth = clamped
        canvasView?.currentMarkerLineWidth = clamped
    }

    private func setArrowStyle(_ style: ArrowStyle) {
        currentArrowStyle = style
        canvasView?.currentArrowStyle = style
        canvasView?.mutateSelectedAnnotationAtomic { annotation in
            guard let arrow = annotation as? ArrowAnnotation else { return annotation }
            return arrow.withStyle(style)
        }
    }

    private func setShapeFillMode(_ mode: ShapeFillMode) {
        currentShapeFillMode = mode
        canvasView?.currentShapeFillMode = mode
        canvasView?.mutateSelectedAnnotationAtomic { $0.withShapeFillMode(mode) }
    }

    private func setShapeStrokeStyle(_ style: ShapeStrokeStyle) {
        currentShapeStrokeStyle = style
        canvasView?.currentShapeStrokeStyle = style
        canvasView?.mutateSelectedAnnotationAtomic { $0.withShapeStrokeStyle(style) }
    }

    private func setCurrentFontSize(_ size: CGFloat) {
        currentFontSize = size
        canvasView?.currentFontSize = size
        canvasView?.mutateSelectedAnnotationAtomic { $0.withFontSize(size) }
    }

    private func setCurrentTextStroke(_ on: Bool) {
        currentTextStroke = on
        canvasView?.currentTextStroke = on
        canvasView?.mutateSelectedAnnotationAtomic { annotation in
            guard let text = annotation as? TextAnnotation else { return annotation }
            return text.withStroke(on)
        }
    }

    private func setCurrentTextCallout(_ on: Bool) {
        currentTextCallout = on
        canvasView?.currentTextCallout = on
        canvasView?.mutateSelectedAnnotationAtomic { annotation in
            guard let text = annotation as? TextAnnotation else { return annotation }
            return text.withCallout(on)
        }
    }

    // MARK: - emoji

    private func showEmojiPopover() {
        let visible = EmojiRecents.choices(from: recentEmojis)
        let initial = currentEmoji ?? visible.first ?? EmojiRecents.defaultRecent[0]
        selectEmoji(initial, promotesToRecent: false)
        installEmojiSubToolbar(visible: visible, selected: initial)
    }

    private func installEmojiSubToolbar(visible: [String], selected: String?) {
        guard let host = hostSelectionView else { return }
        subToolbarView?.removeFromSuperview()
        let width = min(EmojiSubToolbar.preferredVisibleWidth,
                        max(EmojiSubToolbar.minimumVisibleWidth, host.bounds.width - 16))
        let sub = EmojiSubToolbar(frame: NSRect(x: 0, y: 0, width: width, height: 42),
                                  emojis: visible, selectedEmoji: selected)
        sub.onEmojiSelected = { [weak self] emoji in
            self?.selectEmoji(emoji, promotesToRecent: false)
            (self?.subToolbarView as? EmojiSubToolbar)?.selectedEmoji = emoji
        }
        sub.onMoreRequested = { [weak self, weak sub] anchor in
            self?.showEmojiPicker(anchoredTo: anchor, subToolbar: sub)
        }
        placeSubToolbar(sub, in: host)
        subToolbarView = sub
    }

    private func selectEmoji(_ emoji: String, promotesToRecent: Bool) {
        currentEmoji = emoji
        canvasView?.currentEmoji = emoji
        if promotesToRecent, !EmojiRecents.choices(from: recentEmojis).contains(emoji) {
            recentEmojis = EmojiRecents.promoted(emoji, from: recentEmojis)
            Defaults.setRecentEmojis(recentEmojis)
            (subToolbarView as? EmojiSubToolbar)?.emojis = EmojiRecents.choices(from: recentEmojis)
        }
        dismissEmojiPopover()
        bringEditorToFront()
    }

    private func showEmojiPicker(anchoredTo anchor: NSView, subToolbar: EmojiSubToolbar?) {
        dismissEmojiPopover()
        let picker = EmojiPickerView(
            frame: NSRect(origin: .zero, size: EmojiPickerView.preferredSize),
            emojis: EmojiRecents.pickerChoices, selectedEmoji: currentEmoji)
        picker.onEmojiSelected = { [weak self, weak subToolbar] emoji in
            self?.selectEmoji(emoji, promotesToRecent: true)
            subToolbar?.selectedEmoji = emoji
        }
        let vc = NSViewController(); vc.view = picker
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = EmojiPickerView.preferredSize
        popover.contentViewController = vc
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        emojiPopover = popover
    }

    private func dismissEmojiPopover() {
        emojiPopover?.performClose(nil)
        emojiPopover = nil
    }

    private func handleEmojiStamped() {
        currentEmoji = nil
        canvasView?.currentEmoji = nil
        (subToolbarView as? EmojiSubToolbar)?.selectedEmoji = nil
        dismissEmojiPopover()
        NSCursor.arrow.set()
    }

    // MARK: - 输出动作（参照 capcap L1662-1896；副作用经 pipeline）

    /// 确认（复制到剪贴板）。
    /// compositeImage → makeResult → `resultRunner.run(.copy)`，
    /// 失败显示错误（保留编辑器状态，不静默关闭），成功 onComplete(image)。
    func confirm() {
        Self.logger.info("editor.confirm 进入")
        canvasView?.commitActiveTextEditing()
        guard let image = compositeImage() else {
            Self.logger.notice("editor.confirm: compositeImage 失败 → onComplete(nil)")
            presentError(\.annotationErrorNoImage)
            tearDown()
            onComplete(nil)
            return
        }
        guard let result = makeResult(image) else {
            Self.logger.notice("editor.confirm: makeResult 失败 → 保留状态，未 onComplete")
            presentError(\.annotationErrorNoResultMetadata)
            return
        }
        do {
            _ = try resultRunner.run(result: result, intent: .copy, pinOrigin: nil)
            Self.logger.info("editor.confirm 成功 → onComplete(image)")
            tearDown()
            onComplete(image)
        } catch {
            Self.logger.notice("editor.confirm: pipeline 抛错 → 保留状态，未 onComplete")
            presentError(error)
        }
    }

    /// 静默保存到文件。先 tearDown，再 pipeline `.save`；失败仍呈现错误并 onComplete(nil)。
    func save() {
        Self.logger.info("editor.save 进入")
        canvasView?.commitActiveTextEditing()
        guard let image = compositeImage() else {
            Self.logger.notice("editor.save: compositeImage 失败 → 保留状态，未 onComplete")
            presentError(\.annotationErrorNoImage)
            return
        }
        guard let result = makeResult(image) else {
            Self.logger.notice("editor.save: makeResult 失败 → 保留状态，未 onComplete")
            presentError(\.annotationErrorNoResultMetadata)
            return
        }
        // 先拆除 UI（参照 capcap L1669-1670，避免编码阻塞主线程造成卡顿）。
        tearDown()
        do {
            _ = try resultRunner.run(result: result, intent: .save, pinOrigin: nil)
            Self.logger.info("editor.save 成功 → onComplete(nil)")
            onComplete(nil)
        } catch {
            Self.logger.notice("editor.save 抛错 → onComplete(nil)")
            presentError(error)
            onComplete(nil)
        }
    }

    /// 钉图。compositeImage → makeResult → `resultRunner.run(.pin, pinOrigin:)`，
    /// 失败显示错误，成功 onComplete(nil)。
    /// 原位钉住：把选区在屏幕上的左下原点作为钉图窗口原点传入。
    func pin() {
        Self.logger.info("editor.pin 进入")
        canvasView?.commitActiveTextEditing()
        guard let image = compositeImage() else {
            Self.logger.notice("editor.pin: compositeImage 失败 → 保留状态，未 onComplete")
            presentError(\.annotationErrorNoImage)
            return
        }
        guard let result = makeResult(image) else {
            Self.logger.notice("editor.pin: makeResult 失败 → 保留状态，未 onComplete")
            presentError(\.annotationErrorNoResultMetadata)
            return
        }
        do {
            // 选区视图坐标 → 屏幕坐标（AppKit）。hostSelectionView 缺失时回退 nil，退回居中。
            let origin = selectionScreenOrigin()
            _ = try resultRunner.run(result: result, intent: .pin, pinOrigin: origin)
            Self.logger.info("editor.pin 成功 → onComplete(nil)")
            tearDown()
            onComplete(nil)
        } catch {
            Self.logger.notice("editor.pin 抛错 → 保留状态，未 onComplete")
            presentError(error)
        }
    }

    /// 选区左下原点的屏幕坐标（AppKit）。无法计算时返回 nil。
    private func selectionScreenOrigin() -> NSPoint? {
        guard let host = hostSelectionView, let window = host.window else { return nil }
        let windowPoint = host.convert(selectionViewRect.origin, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    /// 取消/关闭。
    func close() {
        Self.logger.info("editor.close 被调用 → onComplete(nil)")
        tearDown()
        onComplete(nil)
    }

    /// 渲染最终图像（底图 + 全部标注）。
    ///
    /// 合成位图按 `sourceBackingScaleFactor` 显式指定像素密度：若用
    /// `NSImage.lockFocus`，其后端密度会跟随隐式主屏 backingScaleFactor，
    /// 与钉住时用的源屏 `pointPixelScale` 不一致，导致多屏 DPI 不同时钉住尺寸
    /// 被放大/缩小。此处与 `BeautifyRenderer.render` 用同一范式：显式建 rep。
    /// 长截图 `previewImage` 优先于 `baseImage`。
    func compositeImage() -> NSImage? {
        let sourceImage = canvasView?.resolveBaseImageForEditing() ?? baseImage
        let size = sourceImage.size
        guard size.width > 0, size.height > 0 else { return sourceImage }

        let pixelsWide = Int((size.width * sourceBackingScaleFactor).rounded())
        let pixelsHigh = Int((size.height * sourceBackingScaleFactor).rounded())
        guard pixelsWide > 0, pixelsHigh > 0 else { return sourceImage }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            return sourceImage
        }
        rep.size = size

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return sourceImage
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = NSRect(origin: .zero, size: size)
        sourceImage.draw(in: bounds)
        for annotation in document.annotations {
            annotation.annotation.drawApplyingTransforms(in: ctx.cgContext, bounds: bounds)
        }

        let composite = NSImage(size: size)
        composite.addRepresentation(rep)

        // 美化（参照 capcap）：底图 + 标注合成后，应用背景/圆角/双层阴影/padding。
        // composite 的 representation 已携带正确 pixelsWide，BeautifyRenderer 据此算对密度。
        if beautifyEnabled {
            let wallpaper = beautifyPreset.isWallpaper ? beautifyWallpaper : nil
            return BeautifyRenderer.render(innerImage: composite, preset: beautifyPreset, wallpaperImage: wallpaper)
        }
        return composite
    }

    // MARK: - 美化（参照 capcap toggleBeautify/applyBeautifyPreset）

    /// 切换美化开关。
    func toggleBeautify() {
        beautifyEnabled.toggle()
        if beautifyEnabled, beautifyPreset.isWallpaper, beautifyWallpaper == nil {
            loadBeautifyWallpaper()
        }
        canvasView?.needsDisplay = true
    }

    /// 切换美化预设。
    func applyBeautifyPreset(_ preset: BeautifyPreset) {
        beautifyPreset = preset
        beautifyEnabled = true
        if preset.isWallpaper, beautifyWallpaper == nil {
            loadBeautifyWallpaper()
        }
        canvasView?.needsDisplay = true
    }

    /// 异步加载当前屏幕桌面壁纸（wallpaper 预设用）。参照 capcap loadBeautifyWallpaper。
    private func loadBeautifyWallpaper() {
        guard let screen = NSScreen.main else { return }
        BeautifyRenderer.loadWallpaperImage(for: screen) { [weak self] image in
            self?.beautifyWallpaper = image
            self?.canvasView?.needsDisplay = true
        }
    }

    // MARK: - 错误反馈

    /// 输出动作失败反馈。记录到 `lastError` 并弹 NSAlert（不关闭编辑器，
    /// 保留状态供用户重试或调整）。参照 capcap ToastWindow，OmniForge 暂用 NSAlert。
    private func presentError(_ error: Error) {
        lastError = error
        showAlert(message: error.localizedDescription)
    }

    /// 用预置的错误文案反馈（避免散落硬编码 key）。
    private func presentError(_ messageKey: KeyPath<Strings, String>) {
        let message = stringsProvider()[keyPath: messageKey]
        lastError = NSError(
            domain: "com.omniforge.annotation-output",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        showAlert(message: message)
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = hostSelectionView?.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    // MARK: - 拆除

    func tearDown() {
        Self.logger.info("editor.tearDown 执行")
        // 停止进行中的长截图，避免回调落到已拆除控制器。
        if isScrollCapturing || isScrollCaptureFinalizing {
            removeScrollCaptureKeyMonitor()
            scrollCapturer?.onPreviewUpdated = nil
            scrollCapturer?.cancelSession()
            scrollCapturer = nil
            isScrollCapturing = false
            isScrollCaptureFinalizing = false
        }
        dismissScrollCaptureChrome()
        dismissInfoToast()
        dismissEmojiPopover()
        removeKeyboardShortcuts()
        selectionChromeOverlay?.removeFromSuperview()
        selectionChromeOverlay = nil
        canvasScrollView?.removeFromSuperview()
        canvasScrollView = nil
        canvasView = nil
        toolbars.forEach { $0.removeFromSuperview() }
        toolbarView = nil
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
    }

    // MARK: - 几何

    private func bringEditorToFront() {
        guard let host = hostSelectionView, let window = host.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if activeTool == .none {
            window.makeFirstResponder(host)
        } else {
            window.makeFirstResponder(canvasView)
        }
    }

    /// 主工具栏位置：选区外缘下方（不够则上方）。参照 capcap
    /// `EditorToolbarPlacement.primaryToolbarRect`。
    private func toolbarRect(in bounds: NSRect, size: NSSize) -> NSRect {
        let reference = selectionViewRect
        let width = ceil(size.width)
        let height = ceil(size.height)
        let margin: CGFloat = 8
        let x = max(margin, min(bounds.maxX - width - margin, reference.midX - width / 2))
        var y = reference.minY - height - margin
        if y < margin {
            y = min(reference.maxY + margin, bounds.maxY - height - margin)
        }
        y = max(margin, min(bounds.maxY - height - margin, y))
        return NSRect(x: round(x), y: round(y), width: width, height: height)
    }

    /// 子工具栏位置：主工具栏下方（不够则上方）。参照 capcap `subToolbarRect`。
    private func subToolbarRect(width: CGFloat, height: CGFloat,
                                toolbarFrame: NSRect, in bounds: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let w = ceil(width)
        let h = ceil(height)
        let x = max(margin, min(bounds.maxX - w - margin, toolbarFrame.midX - w / 2))
        var y = toolbarFrame.minY - h - 4
        if y < margin {
            y = min(toolbarFrame.maxY + 4, bounds.maxY - h - margin)
        }
        y = max(margin, min(bounds.maxY - h - margin, y))
        return NSRect(x: round(x), y: round(y), width: w, height: h)
    }

    private func styleFloatingHUD(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = EditorHUD.shadowOpacity
        view.layer?.shadowRadius = EditorHUD.shadowRadius
        view.layer?.shadowOffset = EditorHUD.shadowOffset
        let shadowBounds = view.bounds.insetBy(dx: 2, dy: 2)
        view.layer?.shadowPath = CGPath(
            roundedRect: shadowBounds,
            cornerWidth: EditorHUD.cornerRadius,
            cornerHeight: EditorHUD.cornerRadius,
            transform: nil
        )
    }

    // MARK: - 键盘快捷键

    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    private func removeKeyboardShortcuts() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // 文字编辑态让出
        if canvasView?.isEditingText == true { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        // 带 command 的快捷键
        switch (key, flags) {
        case ("z", [.command]):
            _ = document.undo()
            canvasView?.needsDisplay = true
            return nil
        case ("z", [.command, .shift]):
            _ = document.redo()
            canvasView?.needsDisplay = true
            return nil
        case ("s", [.command]):
            save()
            return nil
        case ("c", [.command]):
            confirm()
            return nil
        default:
            break
        }

        // 单字母工具快捷键（无修饰）。参照 capcap `EditorKeyboardShortcut`。
        if flags.intersection([.command, .control, .option]).isEmpty,
           let key, key.count == 1 {
            switch key {
            case "v": selectTool(.none); return nil
            case "r": selectTool(.rectangle); return nil
            case "o": selectTool(.ellipse); return nil
            case "l": selectTool(.line); return nil
            case "a": selectTool(.arrow); return nil
            case "d": selectTool(.pen); return nil
            case "h": selectTool(.marker); return nil
            case "m": selectTool(.mosaic); return nil
            case "e": selectTool(.eraser); return nil
            case "t": selectTool(.text); return nil
            case "n": selectTool(.number); return nil
            case "p": pin(); return nil
            case "x": close(); return nil
            default: break
            }
        }

        // 回车确认
        if event.keyCode == 36 { // Return
            if isScrollCapturing {
                stopScrollCapture(reason: "return")
            } else {
                confirm()
            }
            return nil
        }
        // ESC 取消
        if event.keyCode == 53 {
            if isScrollCapturing {
                // 长截图会话中 ESC = 取消：不产出任何图像，恢复编辑器。
                cancelScrollCapture(reason: "escape")
                return nil
            }
            close()
            return nil
        }
        return event
    }

    // MARK: - 长截图编排（手动/自动双模式）

    func toggleScrollCapture() {
        guard isScrollCaptureAllowed else { return }
        guard !isScrollCaptureFinalizing else { return }
        if canvasView?.hasPreviewImage == true { return }
        if isScrollCapturing {
            stopScrollCapture(reason: "toolbar")
        } else {
            startScrollCapture()
        }
    }

    /// 点击工具栏长截图进入滚动捕获会话；滚动驱动模式（手动/自动）由设置决定。
    func startScrollCapture() {
        guard isScrollCaptureAllowed else { return }
        guard !isScrollCaptureBusy else { return }
        guard canvasView?.hasPreviewImage != true else { return }

        canvasView?.commitActiveTextEditing()

        // 1. selectTool none + flags + toolbar active
        selectTool(.none)
        isScrollCapturing = true
        dismissEmojiPopover()
        subToolbarView?.removeFromSuperview()
        subToolbarView = nil
        toolbars.forEach { $0.setScrollCaptureActive(true) }
        hostSelectionView?.scrollCaptureActive = true
        // 画布底图与选区 chrome 会盖住选区；滚动期隐藏，让 dig-out 透出底层实时页面。
        canvasScrollView?.isHidden = true
        selectionChromeOverlay?.isHidden = true
        updateEditorInteractionState()

        // 2. display + flush so chrome is not baked into first frame
        hostSelectionView?.display()
        CATransaction.flush()

        // 3. chrome 先行：HUD 与预览窗要在会话首帧前建好，其窗口 ID 进排除列表。
        showScrollCaptureHUD()
        if scrollPreviewWindow == nil {
            scrollPreviewWindow = ScrollPreviewWindow(
                captureRect: selectionScreenRect(),
                screen: hostSelectionView?.window?.screen ?? NSScreen.main ?? NSScreen()
            )
        }
        toolbars.forEach { $0.isHidden = true }

        // Host overlay + all scroll chrome must be excluded from every frame.
        // Host panel dig-out 露出实时页面；排除 host/chrome 后只采底层内容。
        let excluding = scrollCaptureExcludedWindowIDs()
        Self.logger.info(
            "scroll-capture exclude windows=\(excluding.map(String.init).joined(separator: ","), privacy: .public)"
        )
        let capturer = ScrollCapturer(
            captureRect: captureRect,
            scaleFactor: sourceBackingScaleFactor,
            excludingWindowIDs: excluding,
            config: scrollCaptureSessionConfig()
        )
        capturer.onPreviewUpdated = { [weak self] image in
            DispatchQueue.main.async {
                self?.updateScrollPreview(image)
            }
        }
        capturer.onStripAdded = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateScrollCaptureHUD()
            }
        }
        capturer.onAutoScrollStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.updateScrollCaptureHUD()
            }
        }
        capturer.onSessionDone = { [weak self] stitchedImage in
            DispatchQueue.main.async {
                self?.finishScrollCapture(stitchedImage: stitchedImage)
            }
        }
        scrollCapturer = capturer
        installScrollCaptureKeyMonitor()

        // 4. ignore mouse + deactivate so page under receives scroll
        hostSelectionView?.window?.ignoresMouseEvents = true
        NSApp.deactivate()

        Task { @MainActor [weak capturer] in
            await capturer?.startSession()
        }
    }

    /// 从用户默认值组装会话配置（带取值夹取）。
    private func scrollCaptureSessionConfig() -> ScrollCapturer.SessionConfig {
        let defaults = UserDefaults.standard
        var config = ScrollCapturer.SessionConfig()
        config.autoScrollEnabled = defaults.bool(forKey: UserDefaultsKeys.screenshotScrollAutoScrollEnabled)
        let speed = defaults.integer(forKey: UserDefaultsKeys.screenshotScrollAutoScrollSpeed)
        config.autoScrollSpeed = min(4, max(1, speed))
        let maxHeight = defaults.integer(forKey: UserDefaultsKeys.screenshotScrollMaxHeight)
        config.maxScrollHeight = maxHeight > 0 ? maxHeight : 30_000
        config.frozenDetectionEnabled = defaults.object(forKey: UserDefaultsKeys.screenshotScrollFrozenDetection) as? Bool ?? true
        return config
    }

    /// 停止会话并交付拼接结果。
    func stopScrollCapture(reason: String = "unknown") {
        guard isScrollCapturing else { return }
        isScrollCapturing = false
        isScrollCaptureFinalizing = true
        removeScrollCaptureKeyMonitor()
        let finishingCapturer = scrollCapturer
        finishingCapturer?.onPreviewUpdated = nil
        scrollCapturer = nil
        scrollCaptureHUDWindow?.dismiss()
        scrollCaptureHUDWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        hostSelectionView?.window?.ignoresMouseEvents = false
        hostSelectionView?.scrollCaptureActive = false
        hostSelectionView?.needsDisplay = true
        toolbars.forEach { $0.setScrollCaptureActive(false) }
        canvasScrollView?.isHidden = false
        selectionChromeOverlay?.isHidden = false
        updateEditorInteractionState()

        guard let finishingCapturer else {
            finishScrollCapture(stitchedImage: nil)
            return
        }
        // stopSession 同步触发 onSessionDone → finishScrollCapture。
        finishingCapturer.stopSession()
    }

    /// 取消会话：不产出任何图像，恢复编辑器。首帧采集中也有效。
    func cancelScrollCapture(reason: String = "unknown") {
        guard isScrollCapturing else { return }
        isScrollCapturing = false
        isScrollCaptureFinalizing = false
        removeScrollCaptureKeyMonitor()

        // 先摘回调：在飞的采集/循环不得在取消后交付。
        let cancellingCapturer = scrollCapturer
        scrollCapturer = nil
        cancellingCapturer?.onStripAdded = nil
        cancellingCapturer?.onPreviewUpdated = nil
        cancellingCapturer?.onAutoScrollStarted = nil
        cancellingCapturer?.onSessionDone = nil
        cancellingCapturer?.cancelSession()

        dismissScrollCaptureChrome()
        dismissInfoToast()
        updateEditorInteractionState()
        bringEditorToFront()
        Self.logger.info("scroll-capture cancelled reason=\(reason, privacy: .public)")
    }

    private func finishScrollCapture(stitchedImage: NSImage?) {
        guard isScrollCaptureFinalizing else { return }
        isScrollCaptureFinalizing = false

        guard let stitchedImage else {
            canvasScrollView?.isHidden = false
            selectionChromeOverlay?.isHidden = false
            toolbars.forEach { $0.isHidden = false }
            updateEditorInteractionState()
            bringEditorToFront()
            return
        }
        // 直达交付：编码 → 剪贴板 → tearDown → onComplete。
        completeScrollCapture(with: stitchedImage)
    }

    /// 长截图裁切结果：编码 → 剪贴板 → tearDown → onComplete。
    /// 写入失败时回填编辑器，保留可重试状态（与工具栏 confirm 失败策略一致）。
    private func completeScrollCapture(with image: NSImage) {
        do {
            let output = try encoder.encode(image: image, quality: .original)
            guard clipboardWriter.writeImage(output) else {
                Self.logger.notice("scroll-crop complete: clipboard write failed → keep editor")
                presentError(\.annotationErrorPipelineFormat)
                loadScrollCaptureImageIntoEditor(image)
                toolbars.forEach { $0.isHidden = false }
                bringEditorToFront()
                return
            }
            Self.logger.info("scroll-crop complete: clipboard ok → onComplete(image)")
            tearDown()
            onComplete(image)
        } catch {
            Self.logger.notice("scroll-crop complete: encode failed → keep editor")
            presentError(error)
            loadScrollCaptureImageIntoEditor(image)
            toolbars.forEach { $0.isHidden = false }
            bringEditorToFront()
        }
    }

    private func loadScrollCaptureImageIntoEditor(_ image: NSImage) {
        // Preview wins; baseImage kept for layout fallbacks but composite/draw use preview.
        baseImage = image
        canvasView?.loadPreviewImage(image)
        if let scrollView = canvasScrollView {
            scrollView.hasVerticalScroller = image.size.height > selectionViewRect.height + 0.5
            // Scroll to top of long image (AppKit bottom-left origin).
            let topY = max(0, image.size.height - selectionViewRect.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateEditorInteractionState()
        bringEditorToFront()
    }

    /// Window numbers for chrome that must never bake into scroll frames.
    ///
    /// Critical: the host overlay panel (`hostSelectionView.window`) is full-screen
    /// and holds the frozen selection snapshot. Without excluding it, every long-
    /// scroll frame captures the freeze overlay instead of the live page underneath.
    private func scrollCaptureExcludedWindowIDs() -> [CGWindowID] {
        ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: hostSelectionView?.window?.windowNumber,
            hudWindowNumber: scrollCaptureHUDWindow?.windowNumber,
            previewWindowNumber: scrollPreviewWindow?.windowNumber,
            toastWindowNumber: infoToastWindow?.windowNumber
        )
    }

    /// Test hook: same exclusion builder used before `ScrollCapturer` init.
    func scrollCaptureExcludedWindowIDsForTesting(
        hostWindowNumber: Int?,
        hudWindowNumber: Int? = nil,
        previewWindowNumber: Int? = nil,
        toastWindowNumber: Int? = nil
    ) -> [CGWindowID] {
        return ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: hostWindowNumber,
            hudWindowNumber: hudWindowNumber,
            previewWindowNumber: previewWindowNumber,
            toastWindowNumber: toastWindowNumber
        )
    }

    private func updateScrollPreview(_ image: NSImage) {
        guard isScrollCapturing else { return }
        scrollPreviewWindow?.updatePreview(image)
    }

    /// HUD 进度刷新（信息条尺寸 + 自动滚动按钮状态）。
    private func updateScrollCaptureHUD() {
        guard let hud = scrollCaptureHUDWindow, let capturer = scrollCapturer else { return }
        hud.update(
            pixelSize: capturer.stitchedPixelSize,
            backingScale: sourceBackingScaleFactor,
            autoScrolling: capturer.autoScrollActive
        )
    }

    private func showScrollCaptureHUD() {
        let strings = stringsProvider()
        let hud = ScrollCaptureHUDWindow(
            title: strings.tipScrollCapture,
            autoTitle: strings.scrollCaptureAutoScroll,
            scrollingTitle: strings.scrollCaptureScrolling,
            stopTitle: strings.scrollCaptureStop,
            onStop: { [weak self] in
                self?.stopScrollCapture(reason: "hud-stop")
            },
            onToggleAutoScroll: { [weak self] in
                self?.handleScrollCaptureToggleAutoScroll()
            }
        )
        hud.position(
            relativeTo: selectionScreenRect(),
            on: hostSelectionView?.window?.screen ?? NSScreen.main ?? NSScreen()
        )
        scrollCaptureHUDWindow = hud
    }

    /// HUD「自动滚动」切换：切向自动前做辅助功能权限门。
    private func handleScrollCaptureToggleAutoScroll() {
        guard let capturer = scrollCapturer, isScrollCapturing else { return }
        if !capturer.autoScrollActive, !AXIsProcessTrusted() {
            presentScrollCaptureAccessibilityPrompt()
            return
        }
        capturer.toggleAutoScroll()
        updateScrollCaptureHUD()
    }

    /// 辅助功能权限引导：弹窗 + 直达系统设置。
    private func presentScrollCaptureAccessibilityPrompt() {
        let strings = stringsProvider()
        let alert = NSAlert()
        alert.messageText = strings.scrollCaptureAccessibilityTitle
        alert.informativeText = strings.scrollCaptureAccessibilityBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: strings.scrollCaptureOpenSettings)
        alert.addButton(withTitle: strings.scrollCaptureCancel)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func installScrollCaptureKeyMonitor() {
        removeScrollCaptureKeyMonitor()
        scrollCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self, self.isScrollCapturing else { return }
            DispatchQueue.main.async {
                self.cancelScrollCapture(reason: "global-key")
            }
        }
    }

    private func removeScrollCaptureKeyMonitor() {
        if let scrollCaptureKeyMonitor {
            NSEvent.removeMonitor(scrollCaptureKeyMonitor)
            self.scrollCaptureKeyMonitor = nil
        }
    }

    private func dismissScrollCaptureChrome() {
        scrollCaptureHUDWindow?.dismiss()
        scrollCaptureHUDWindow = nil
        scrollPreviewWindow?.dismiss()
        scrollPreviewWindow = nil
        hostSelectionView?.window?.ignoresMouseEvents = false
        hostSelectionView?.scrollCaptureActive = false
        canvasScrollView?.isHidden = false
        selectionChromeOverlay?.isHidden = false
        toolbars.forEach { $0.setScrollCaptureActive(false) }
        toolbars.forEach { $0.isHidden = false }
    }

    private func dismissInfoToast() {
        infoToastWindow?.dismiss()
        infoToastWindow = nil
    }

    /// Selection rect in AppKit screen coordinates.
    private func selectionScreenRect() -> NSRect {
        guard let host = hostSelectionView, let window = host.window else {
            return selectionViewRect
        }
        let windowRect = host.convert(selectionViewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    private func presentInfoMessage(_ message: String) {
        // Non-blocking toast (permission / hard errors stay on NSAlert).
        Self.logger.info("scroll-capture: \(message, privacy: .public)")
        let toast = infoToastWindow ?? EditorInfoToastWindow()
        infoToastWindow = toast
        let screen = hostSelectionView?.window?.screen ?? NSScreen.main
        toast.present(message, near: screen)
    }
}
