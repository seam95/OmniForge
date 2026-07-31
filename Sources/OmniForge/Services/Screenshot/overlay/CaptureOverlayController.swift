import AppKit
import CoreGraphics
import QuartzCore
import os.log

/// 多屏遮罩总编排。
///
/// 职责：预抓快照 → 建每屏遮罩面板 → 选区交互 →（可选）嵌入标注编辑器 →
/// 结果回调 → 清理。
///
/// 编辑器嵌入模式（参照 capcap `OverlayWindowController` L912-951）：
/// 选区完成后**不关 overlay**，而是在该屏的 SelectionView 内嵌入
/// `AnnotationEditorController`（与选区共享窗口）。编辑器关闭时再统一
/// tearDown 并把合成图回传。
@MainActor
final class CaptureOverlayController {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "ScreenshotOverlay")

    private var overlayPanels: [NSWindow] = []
    private var selectionViews: [NSWindow: SelectionView] = [:]
    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]
    /// panel → 该屏 CGDirectDisplayID；建 panel 时记录，apply 时直接查，
    /// 不依赖事后 `panel.screen`（headless/热插拔/tearDown 后不可靠）。
    private var panelDisplayIDs: [NSWindow: CGDirectDisplayID] = [:]
    /// tearDown 守卫；startCapture 入口时 overlayPanels 仍为空，不能用集合判活。
    private var isTornDown = true
    /// 会话代际：startCapture / tearDown 递增，防止复用 controller 时旧 Task.detached 冻屏写入新会话。
    private(set) var snapshotGeneration: UInt64 = 0
    private var escLocalMonitor: Any?
    private var escGlobalMonitor: Any?
    private var rightMouseMonitor: Any?
    /// 多屏 hover 路由：用 mouseLocation 驱动当前屏的吸附，不依赖各 panel 是否 key。
    private var hoverMoveLocalMonitor: Any?
    private var hoverMoveGlobalMonitor: Any?
    private var lastHoverPanel: NSWindow?

    /// 测试钩子：`startCapture` 入口调用（生产保持 nil）。
    var onStartCaptureForTesting: (() -> Void)?
    /// 测试钩子：`applyScreenSnapshots` 被接受时调用（生产保持 nil）。
    var onApplySnapshotsForTesting: (([CGDirectDisplayID: CGImage]) -> Void)?

    /// 当前嵌入的标注编辑器（编辑器模式下非空）。
    private var editorController: AnnotationEditorController?
    /// 编辑器嵌入所在的 SelectionView（编辑器模式下非空）。
    private weak var editorHostView: SelectionView?

    private var onComplete: ((NSImage?) -> Void)?
    private var activeScreen: NSScreen?
    private var captureClient: ScreenCaptureClient?
    /// 是否在选区完成后嵌入标注编辑器。全屏/纯捕获流程可关闭。
    private let editorEnabled: Bool

    // 阶段 5 输出依赖（透传给编辑器）
    private let outputEncoder: ImageOutputEncoding?
    private let clipboardWriter: ClipboardImageWriting?
    private let screenshotSaver: ScreenshotSaving?
    /// 保存时现场读取输出配置（目录/前缀）；兼容旧路径 / 默认 pipeline 构造。
    private let outputConfigurationProvider: () -> ScreenshotOutputConfigurationSnapshot
    /// 与钉图 registry 共享的结果管线；confirm/save/pin 经此出口。
    private var resultPipeline: ScreenshotResultPipeline?
    private let pinResultBuilder: ((NSImage) -> ScreenshotResult?)?

    /// 注入共享结果管线（FeatureFactory 在装配 pinBridge 后设置）。
    func setResultPipeline(_ pipeline: ScreenshotResultPipeline?) {
        resultPipeline = pipeline
    }

    /// 兼容旧调用：仅设置 pinService（会落到已注入的 pipeline 上）。
    func setPinService(_ service: ScreenshotPinning?) {
        resultPipeline?.pinService = service
    }

    /// 选区录屏回调：编辑器 tearDown 后由 manager/coordinator 启动录屏。
    /// 参数必须是 AppKit screen rect。
    var onRecordingSelection: ((NSRect, NSScreen) -> Void)?

    /// 选区完成后直接回调 AppKit screen rect（跳过编辑器）。
    /// 用于独立录屏快捷键：框选 → 立即 begin recording。
    /// **禁止**复用此回调承载 copy/pin（仅 rect，无图像）；见 `onDirectCaptureResult`。
    var onDirectRegionSelection: ((NSRect, NSScreen) -> Void)?

    /// 入口意图：`.copy` / `.pin` 时选区确认后直出到 `onDirectCaptureResult`，不进编辑器。
    /// 与录屏 `onDirectRegionSelection` 语义解耦；会话结束 / tearDown 时清空。
    var entryIntent: ScreenshotEntryIntent?

    /// copy/pin 选区直出：裁切图 + `ScreenshotResult` + 可选 pinOrigin（选区屏幕左下）。
    /// 与 `onDirectRegionSelection`（rect-only 录屏）互不覆盖。
    var onDirectCaptureResult: ((ScreenshotResult, ScreenshotEntryIntent, NSPoint?) -> Void)?

    /// 按捕获入口构造 makeResult 闭包。
    /// - 优先用注入的 `pinResultBuilder`（测试/兼容）。
    /// - 否则用具体 mode + 目标屏 +（区域路径）选区视图矩形构造 `ScreenshotResult`。
    private func makeResultBuilder(
        mode: ScreenshotMode,
        screen: NSScreen?,
        selectionViewRect: NSRect?
    ) -> (NSImage) -> ScreenshotResult? {
        if let pinResultBuilder { return pinResultBuilder }
        return { [weak self] image in
            guard let self else { return nil }
            return self.buildScreenshotResult(
                from: image,
                mode: mode,
                screen: screen,
                selectionViewRect: selectionViewRect
            )
        }
    }

    /// 从合成图与捕获上下文构造 `ScreenshotResult`。
    /// - selectionViewRect：SelectionView 局部坐标（与屏 frame 同原点时 + frame.origin → AppKit 全局）。
    ///   全屏路径传 nil；区域 / all-in-one 传选区矩形。
    private func buildScreenshotResult(
        from image: NSImage,
        mode: ScreenshotMode,
        screen: NSScreen?,
        selectionViewRect: NSRect?
    ) -> ScreenshotResult? {
        guard let screen, let displayID = screen.displayID else { return nil }
        let target = CaptureTargetScreen(
            displayID: displayID,
            frameInAppKitPoints: screen.frame,
            pointPixelScale: screen.backingScaleFactor
        )
        return Self.buildScreenshotResult(
            from: image,
            mode: mode,
            targetScreen: target,
            selectionViewLocalRect: selectionViewRect
        )
    }

    /// 纯上下文构造（可单测，不依赖 live `NSScreen`）。
    /// selectionViewLocalRect 为选区在目标屏局部（左下原点）的点矩形；nil 表示无选区（全屏）。
    static func buildScreenshotResult(
        from image: NSImage,
        mode: ScreenshotMode,
        targetScreen: CaptureTargetScreen,
        selectionViewLocalRect: CGRect?
    ) -> ScreenshotResult? {
        guard let cgImage = image.cgImagePreservingBacking()
                ?? (image.representations.first as? NSBitmapImageRep)?.cgImage else {
            return nil
        }

        let selection: CaptureSelection?
        if let local = selectionViewLocalRect {
            let frame = targetScreen.frameInAppKitPoints
            let appKitGlobal = CGRect(
                x: local.origin.x + frame.minX,
                y: local.origin.y + frame.minY,
                width: local.width,
                height: local.height
            )
            selection = try? CaptureSelection(
                targetScreen: targetScreen,
                appKitGlobalRect: appKitGlobal
            )
            // allInOne 必须有合法 selection；构造失败则整条 makeResult 失败，避免伪造成功。
            if mode == .allInOne, selection == nil {
                return nil
            }
        } else {
            selection = nil
        }

        return try? ScreenshotResult(
            mode: mode,
            targetScreen: targetScreen,
            selection: selection,
            timestamp: Date(),
            pixelImage: cgImage,
            windowInfo: nil
        )
    }

    /// 解析编辑器使用的 pipeline：优先共享实例，否则用本地默认（无 pinService）。
    private func resolvedResultPipeline() -> ScreenshotResultPipeline {
        if let resultPipeline { return resultPipeline }
        return ScreenshotResultPipeline(
            encoder: outputEncoder ?? ImageOutputEncoder(),
            clipboardWriter: clipboardWriter ?? ClipboardImageWriter(),
            saver: screenshotSaver ?? ScreenshotSaver(),
            outputConfigurationProvider: outputConfigurationProvider
        )
    }

    /// 使用指定的捕获客户端初始化。
    /// - Parameter editorEnabled: 选区完成后是否嵌入标注编辑器。
    /// - Parameters outputEncoder/clipboardWriter/screenshotSaver/resultPipeline/pinResultBuilder:
    ///   输出依赖透传给编辑器；`resultPipeline` 可后置 `setResultPipeline`。
    init(captureClient: ScreenCaptureClient? = nil,
         editorEnabled: Bool = true,
         outputEncoder: ImageOutputEncoding? = nil,
         clipboardWriter: ClipboardImageWriting? = nil,
         screenshotSaver: ScreenshotSaving? = nil,
         outputConfigurationProvider: @escaping () -> ScreenshotOutputConfigurationSnapshot = {
             ScreenshotOutputConfiguration().load()
         },
         resultPipeline: ScreenshotResultPipeline? = nil,
         pinResultBuilder: ((NSImage) -> ScreenshotResult?)? = nil) {
        self.captureClient = captureClient
        self.editorEnabled = editorEnabled
        self.outputEncoder = outputEncoder
        self.clipboardWriter = clipboardWriter
        self.screenshotSaver = screenshotSaver
        self.outputConfigurationProvider = outputConfigurationProvider
        self.resultPipeline = resultPipeline
        self.pinResultBuilder = pinResultBuilder
    }

    /// 启动捕获流程。
    /// - Parameters:
    ///   - screenSnapshots: 预抓的每屏快照（可选）。
    ///   - completion: 流程完成后的回调（编辑器模式下为合成图或 nil，
    ///     纯捕获模式下为选区裁切图或 nil）。
    func startCapture(
        screenSnapshots preSnapshots: [CGDirectDisplayID: CGImage] = [:],
        completion: @escaping (NSImage?) -> Void
    ) {
        Self.logger.info("[SSDBG] startCapture: 入口，设置 onComplete")
        self.isTornDown = false
        self.snapshotGeneration &+= 1
        self.screenSnapshots = preSnapshots
        self.onComplete = completion

        // 为每块屏幕创建遮罩面板
        for screen in NSScreen.screens {
            let panel = createOverlayPanel(for: screen)
            overlayPanels.append(panel)

            let selectionView = SelectionView(frame: screen.frame)
            selectionView.delegate = self

            // 注入窗口吸附 provider（按权限选 AX 或 SC 降级）。
            selectionView.snapProvider = makeSnapProvider()
            // 屏 frame 来源：用 SelectionView 所在 panel 的 screen。
            selectionView.screenFrameProvider = { [weak panel] in panel?.screen?.frame }
            // visibleFrame 来源（已扣除菜单栏/Dock，用于边缘条带吸附）。
            selectionView.visibleFrameProvider = { [weak panel] in panel?.screen?.visibleFrame }
            // CG/AX 全局坐标以主屏高度为 Y 翻转基准（上下/不等高多屏必需）。
            selectionView.primaryDisplayHeightProvider = {
                NSScreen.screens.first?.frame.maxY
            }

            // 注入底图快照（仅用预抓；缺图时保持 nil，暗罩可先出，后续 apply 补图）
            if let displayID = screen.displayID {
                panelDisplayIDs[panel] = displayID
                selectionView.backgroundSnapshot = preSnapshots[displayID]
            }

            panel.contentView = selectionView
            selectionViews[panel] = selectionView
        }

        // 安装 ESC / 右键 / 多屏 hover 路由
        installCancellationMonitors()
        installHoverRoutingMonitors()

        // 批量显示（禁用动画避免闪烁）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for panel in overlayPanels {
            panel.orderFront(nil)
        }
        CATransaction.commit()

        // 启动后立即按当前鼠标位置刷一次 hover（不依赖先收到 mouseMoved）。
        routeHover(to: NSEvent.mouseLocation)

        onStartCaptureForTesting?()
    }

    /// 冻屏完成后注入/更新各屏底图。tearDown 后或 generation 不匹配时 no-op。
    /// displayID 取自建 panel 时记录的 `panelDisplayIDs`，不反查 `panel.screen`。
    func applyScreenSnapshots(_ snapshots: [CGDirectDisplayID: CGImage], generation: UInt64) {
        guard !isTornDown, generation == snapshotGeneration else { return }
        // 合并到内部字典：即便没有匹配 panel（如 headless），selectionDidComplete 仍可裁切
        for (displayID, image) in snapshots {
            screenSnapshots[displayID] = image
        }
        // 仅更新存活 overlay 上能匹配 displayID 的 SelectionView
        for (panel, view) in selectionViews {
            guard let displayID = panelDisplayIDs[panel],
                  let image = snapshots[displayID] else { continue }
            view.backgroundSnapshot = image  // didSet 触发重绘
        }
        onApplySnapshotsForTesting?(snapshots)
    }

    /// 直接以一张预捕获图像进入编辑器（全屏截图路径用）。
    ///
    /// 不经过选区阶段：在鼠标所在屏建一个满屏 SelectionView，把传入图像
    /// 作为底图，自动以整屏矩形为选区并嵌入编辑器。
    /// - Parameters:
    ///   - baseImage: 预捕获的整屏图像。
    ///   - screen: 展示用的屏。
    ///   - completion: 编辑器关闭后的回调。
    func startEditor(
        with baseImage: NSImage,
        on screen: NSScreen,
        completion: @escaping (NSImage?) -> Void
    ) {
        Self.logger.info("[SSDBG] startEditor: 入口，设置 onComplete")
        self.onComplete = completion

        let panel = createOverlayPanel(for: screen)
        overlayPanels.append(panel)

        let selectionView = SelectionView(frame: screen.frame)
        selectionView.delegate = self
        if let displayID = screen.displayID {
            selectionView.backgroundSnapshot = screenSnapshots[displayID]
        }
        panel.contentView = selectionView
        selectionViews[panel] = selectionView

        installCancellationMonitors()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.orderFront(nil)
        CATransaction.commit()

        // 整屏矩形作为选区 → 直接进入编辑器。
        let fullRect = NSRect(origin: .zero, size: screen.frame.size)
        let fullCaptureRect = convertToCGRect(fullRect, on: screen)
        let displayID = screen.displayID
        let preSnapshot = displayID.flatMap { screenSnapshots[$0] }
        selectionView.selectionLocked = true
        selectionView.selectionInteractionEnabled = true
        selectionView.annotationToolActive = true
        editorHostView = selectionView
        // 禁用其余屏的选区交互（当前 startEditor 虽只建单屏 panel，保留防御）。
        disableSelectionInteractionOnOtherScreens(keeping: selectionView)

        let encoder = outputEncoder ?? ImageOutputEncoder()
        let clipboard = clipboardWriter ?? ClipboardImageWriter()
        let editor = AnnotationEditorController(
            baseImage: baseImage,
            document: AnnotationDocument(),
            resultRunner: resolvedResultPipeline(),
            encoder: encoder,
            clipboardWriter: clipboard,
            makeResult: makeResultBuilder(
                mode: .fullScreen,
                screen: screen,
                selectionViewRect: nil
            ),
            sourceBackingScaleFactor: screen.backingScaleFactor,
            onComplete: { [weak self] finalImage in
                guard let self else { return }
                Self.logger.info("[SSDBG] startEditor 编辑器 onComplete(#1) 被调用，image=\(finalImage != nil)")
                self.tearDown()
                self.onComplete?(finalImage)
                self.onComplete = nil
            }
        )
        editor.onRecordingSelection = onRecordingSelection
        editorController = editor
        editor.show(
            in: selectionView,
            selectionRect: fullRect,
            captureRect: fullCaptureRect,
            preSnapshot: preSnapshot,
            displayID: displayID
        )
    }

    /// 清理遮罩和监听器。
    func tearDown() {
        // Always drop direct-record callback so a cancelled dedicated-record
        // selection cannot hijack the next all-in-one region complete.
        onDirectRegionSelection = nil
        // copy/pin 直出状态同步清空，避免残留劫持后续全能/录屏路径。
        onDirectCaptureResult = nil
        entryIntent = nil

        // 先拆除编辑器（避免它继续持有画布）
        editorController?.tearDown()
        editorController = nil
        editorHostView?.selectionLocked = false
        editorHostView?.selectionInteractionEnabled = true
        editorHostView?.annotationToolActive = false
        editorHostView?.scrollCaptureActive = false
        editorHostView = nil

        // 移除监听器
        if let monitor = escLocalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = escGlobalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = rightMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = hoverMoveLocalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = hoverMoveGlobalMonitor { NSEvent.removeMonitor(monitor) }
        escLocalMonitor = nil
        escGlobalMonitor = nil
        rightMouseMonitor = nil
        hoverMoveLocalMonitor = nil
        hoverMoveGlobalMonitor = nil
        lastHoverPanel = nil

        // 关闭面板
        for panel in overlayPanels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        overlayPanels.removeAll()
        selectionViews.removeAll()
        screenSnapshots.removeAll()
        panelDisplayIDs.removeAll()
        isTornDown = true
        snapshotGeneration &+= 1
    }

    // MARK: - 遮罩面板创建

    private func createOverlayPanel(for screen: NSScreen) -> NSPanel {
        let frame = screen.frame
        let panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.setFrame(frame, display: false)
        return panel
    }

    // MARK: - 取消监听

    private func installCancellationMonitors() {
        // ESC 本地监听
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.handleCancel()
                return nil
            }
            return event
        }
        // ESC 全局监听
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.handleCancel()
            }
        }
        // 右键监听（仅选区阶段；编辑器嵌入后由编辑器自身接管）
        rightMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            guard let self else { return }
            guard self.editorController == nil else { return }
            self.handleCancel()
        }
    }

    /// 多屏吸附路由：以 `NSEvent.mouseLocation` 选当前屏 SelectionView 更新 hover。
    /// 不依赖各 overlay 是否 key / tracking 是否稳定。
    private func installHoverRoutingMonitors() {
        hoverMoveLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.routeHover(to: NSEvent.mouseLocation)
            return event
        }
        hoverMoveGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.routeHover(to: NSEvent.mouseLocation)
        }
    }

    private func routeHover(to mouseAppKitGlobal: NSPoint) {
        // 编辑器嵌入后吸附关闭。
        guard editorController == nil else { return }

        let screens: [SnapHoverScreen] = overlayPanels.compactMap { panel in
            guard let frame = panel.screen?.frame ?? selectionViews[panel].map({ _ in panel.frame }) else {
                return nil
            }
            return SnapHoverScreen(id: String(panel.windowNumber), frame: frame)
        }
        guard let target = SnapHoverRouter.target(
            mouseAppKitGlobal: mouseAppKitGlobal,
            screens: screens
        ) else {
            if let last = lastHoverPanel, let view = selectionViews[last] {
                view.clearHoverFromRouter()
            }
            lastHoverPanel = nil
            return
        }

        let targetPanel = overlayPanels.first { String($0.windowNumber) == target.id }
        if let last = lastHoverPanel, last !== targetPanel, let view = selectionViews[last] {
            view.clearHoverFromRouter()
        }
        lastHoverPanel = targetPanel
        guard let panel = targetPanel, let view = selectionViews[panel] else { return }
        view.updateHoverFromRouter(at: NSPoint(x: target.localPoint.x, y: target.localPoint.y))
    }

    private func handleCancel() {
        Self.logger.info("[SSDBG] handleCancel(#2) 被调用")
        tearDown()
        onComplete?(nil)
        onComplete = nil
    }

    // MARK: - 窗口吸附

    /// 按权限选择窗口吸附 provider。
    /// - AX 已授权 → AXWindowSnapProvider（窗口 + 元素级）
    /// - AX 未授权 → SCWindowSnapProvider（仅整窗，降级）
    private func makeSnapProvider() -> WindowSnapProvider {
        if Permissions.shared.accessibility {
            return AXWindowSnapProvider()
        }
        Self.logger.info("[ScreenshotOverlay] AX 未授权，窗口吸附降级为整窗模式")
        return SCWindowSnapProvider()
    }

    // MARK: - 坐标转换

    /// AppKit 视图坐标 → CG 全局坐标（主屏高度为 Y 翻转基准）。
    private func convertToCGRect(_ viewRect: NSRect, on screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        // 顶边：AppKit maxY → CG 矩形 origin.y
        let topLeft = SnapCoordinate.cgPoint(
            viewPoint: NSPoint(x: viewRect.minX, y: viewRect.maxY),
            screenFrame: screen.frame,
            primaryDisplayHeight: primaryHeight
        )
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: viewRect.width,
            height: viewRect.height
        )
    }
}

// MARK: - SelectionViewDelegate

extension CaptureOverlayController: SelectionViewDelegate {
    func selectionDidComplete(rect: NSRect) {
        // 二次 complete：编辑器已存在 → 仅 updateLayout，不重建。
        if let editor = editorController {
            applySelectionChange(rect: rect, to: editor)
            return
        }

        guard let panel = overlayPanels.first(where: { selectionViews[$0]?.currentSelectionRect != nil }),
              let screen = panel.screen,
              let displayID = screen.displayID,
              let selectionView = selectionViews[panel] else {
            Self.logger.notice("[SSDBG] selectionDidComplete(#3) guard 失败：找不到选区面板")
            tearDown()
            onComplete?(nil)
            onComplete = nil
            return
        }

        // 独立录屏入口：框选后直接交出 AppKit screen rect，不进编辑器。
        if let onDirectRegionSelection {
            let windowRect = selectionView.convert(rect, to: nil)
            let screenRect = panel.convertToScreen(windowRect)
            let callback = onDirectRegionSelection
            self.onDirectRegionSelection = nil
            tearDown()
            onComplete?(nil)
            onComplete = nil
            callback(screenRect, screen)
            return
        }

        // 视图坐标 → CG 坐标
        let captureRect = convertToCGRect(rect, on: screen)
        let windowRect = selectionView.convert(rect, to: nil)
        let screenRect = panel.convertToScreen(windowRect)
        // pinOrigin：选区屏幕左下原点（AppKit）；无法计算时由 pinService 居中。
        let pinOrigin = NSPoint(x: screenRect.minX, y: screenRect.minY)

        // copy/pin 直出：裁切图 → ScreenshotResult → 回调 manager，不进编辑器。
        if let intent = entryIntent, intent == .copy || intent == .pin {
            deliverDirectCapture(
                intent: intent,
                selectionViewRect: rect,
                captureRect: captureRect,
                pinOrigin: pinOrigin,
                screen: screen,
                displayID: displayID
            )
            return
        }

        // 优先从预抓快照裁切
        if let snapshot = screenSnapshots[displayID],
           let cropped = snapshot.croppingToSelection(globalRect: captureRect, displayID: displayID) {
            let image = NSImage(cgImage: cropped, size: rect.size)
            handleCapturedImage(
                image,
                selectionRect: rect,
                selectionView: selectionView,
                captureRect: captureRect,
                preSnapshot: snapshot,
                displayID: displayID
            )
            return
        }

        // 回退：实时捕获
        guard let client = captureClient else {
            Self.logger.notice("[SSDBG] selectionDidComplete(#4) 无 captureClient")
            tearDown()
            onComplete?(nil)
            onComplete = nil
            return
        }

        let preSnapshot = screenSnapshots[displayID]
        Task { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await client.captureRegion(captureRect, displayID: displayID, scaleFactor: screen.backingScaleFactor)
                let image = NSImage(cgImage: cgImage, size: rect.size)
                await MainActor.run {
                    self.handleCapturedImage(
                        image,
                        selectionRect: rect,
                        selectionView: selectionView,
                        captureRect: captureRect,
                        preSnapshot: preSnapshot,
                        displayID: displayID
                    )
                }
            } catch {
                await MainActor.run {
                    Self.logger.notice("[SSDBG] captureRegion(#5) 抛错：\(error.localizedDescription)")
                    self.tearDown()
                    self.onComplete?(nil)
                    self.onComplete = nil
                }
            }
        }
    }

    /// copy/pin 选区直出：裁切图像、组装 `ScreenshotResult`、tearDown 后回调。
    private func deliverDirectCapture(
        intent: ScreenshotEntryIntent,
        selectionViewRect: NSRect,
        captureRect: CGRect,
        pinOrigin: NSPoint,
        screen: NSScreen,
        displayID: CGDirectDisplayID
    ) {
        let callback = onDirectCaptureResult
        // 先清空直出状态，避免 tearDown 后残留；回调在 tearDown 之后触发。
        onDirectCaptureResult = nil
        entryIntent = nil

        // 优先预抓快照裁切
        if let snapshot = screenSnapshots[displayID],
           let cropped = snapshot.croppingToSelection(globalRect: captureRect, displayID: displayID) {
            let image = NSImage(cgImage: cropped, size: selectionViewRect.size)
            finishDirectCapture(
                image: image,
                intent: intent,
                selectionViewRect: selectionViewRect,
                pinOrigin: pinOrigin,
                screen: screen,
                callback: callback
            )
            return
        }

        // 回退：实时 captureRegion
        guard let client = captureClient else {
            Self.logger.notice("[SSDBG] deliverDirectCapture: 无 captureClient")
            tearDown()
            onComplete?(nil)
            onComplete = nil
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await client.captureRegion(
                    captureRect,
                    displayID: displayID,
                    scaleFactor: screen.backingScaleFactor
                )
                let image = NSImage(cgImage: cgImage, size: selectionViewRect.size)
                await MainActor.run {
                    self.finishDirectCapture(
                        image: image,
                        intent: intent,
                        selectionViewRect: selectionViewRect,
                        pinOrigin: pinOrigin,
                        screen: screen,
                        callback: callback
                    )
                }
            } catch {
                await MainActor.run {
                    Self.logger.notice(
                        "[SSDBG] deliverDirectCapture captureRegion 抛错：\(error.localizedDescription)"
                    )
                    self.tearDown()
                    self.onComplete?(nil)
                    self.onComplete = nil
                }
            }
        }
    }

    /// 直出收尾：构造 result → tearDown → 回调 manager（pipeline 由 manager 执行）。
    private func finishDirectCapture(
        image: NSImage,
        intent: ScreenshotEntryIntent,
        selectionViewRect: NSRect,
        pinOrigin: NSPoint,
        screen: NSScreen,
        callback: ((ScreenshotResult, ScreenshotEntryIntent, NSPoint?) -> Void)?
    ) {
        guard let result = buildScreenshotResult(
            from: image,
            mode: .allInOne,
            screen: screen,
            selectionViewRect: selectionViewRect
        ) else {
            Self.logger.notice("[SSDBG] finishDirectCapture: 构造 ScreenshotResult 失败")
            tearDown()
            onComplete?(nil)
            onComplete = nil
            return
        }

        Self.logger.info("[SSDBG] finishDirectCapture: intent=\(intent.rawValue)，直出完成")
        // Callback manager (pipeline) before session completion so awaitingDirectCaptureResult
        // is settled before onComplete clears the session — avoids false failure on success.
        // pinOrigin 仅 pin 有意义；copy 也传入无害，manager 可忽略。
        callback?(result, intent, pinOrigin)
        tearDown()
        onComplete?(nil)
        onComplete = nil
    }

    func selectionDidChange(rect: NSRect) {
        guard let editor = editorController else { return }
        applySelectionChange(rect: rect, to: editor)
    }

    func selectionDidCancel() {
        handleCancel()
    }

    /// 选区移动/缩放：只更新 layout（captureRect + chrome 重排）。
    /// 不重裁底图——canvas draw 时按 `captureRect` 从 `preSnapshot` 现裁，
    /// 冻结背景与选区框解耦，避免拖动闪烁（对齐 CapCap）。
    /// 不重建 `AnnotationEditorController`，不清空 `document.annotations`。
    private func applySelectionChange(rect: NSRect, to editor: AnnotationEditorController) {
        guard let panel = overlayPanels.first(where: { selectionViews[$0] === editorHostView })
                ?? overlayPanels.first(where: { selectionViews[$0]?.currentSelectionRect != nil }),
              let screen = panel.screen else {
            // 无法定位屏幕时仍更新视图布局，避免 chrome 卡死。
            editor.updateLayout(selectionViewRect: rect, captureRect: editor.captureRect)
            return
        }
        let captureRect = convertToCGRect(rect, on: screen)
        editor.updateLayout(selectionViewRect: rect, captureRect: captureRect)
    }

    /// 编辑器嵌入宿主屏后，禁用其余屏 SelectionView 的选区交互并清除可视残留。
    ///
    /// 多屏截图场景下编辑器只与宿主屏共享窗口。若不锁住其他屏，在副屏点击会
    /// 触发该屏 `selectionDidComplete`，其局部坐标会被宿主屏 frame 翻转，
    /// 污染编辑器的 captureRect 并撑大画布底图（宿主屏内容被拉扯）。
    /// 编辑器模式下不支持跨屏重选，统一禁用即可；副屏遮罩仍保留以示截图进行中。
    ///
    /// 仅设 `selectionInteractionEnabled = false` 不够：`draw` 的 hover 高亮
    /// 分支不受该标志控制，副屏残留的 `hoverRect`（鼠标移向副屏时由路由器
    /// 设置，编辑器嵌入前最后一帧）会持续显示绿色边框，视觉等同选区高亮。
    /// 故同时调用 `clearSelection()` 清掉 hover/pending/selectionRect 并重绘。
    private func disableSelectionInteractionOnOtherScreens(keeping hostView: SelectionView) {
        for view in selectionViews.values where view !== hostView {
            view.selectionInteractionEnabled = false
            view.clearSelection()
        }
    }

    /// 选区裁切图就绪：进入编辑器或直接回调。
    private func handleCapturedImage(
        _ image: NSImage,
        selectionRect: NSRect,
        selectionView: SelectionView,
        captureRect: CGRect,
        preSnapshot: CGImage?,
        displayID: CGDirectDisplayID?
    ) {
        guard editorEnabled else {
            // 纯捕获模式：直接回调并拆除
            Self.logger.info("[SSDBG] handleCapturedImage(#6) 纯捕获模式完成")
            tearDown()
            onComplete?(image)
            onComplete = nil
            return
        }

        // 编辑器模式：在 SelectionView 内嵌入编辑器，与之共享窗口。
        Self.logger.info("[SSDBG] handleCapturedImage: 进入编辑器模式，等待编辑器 onComplete")
        selectionView.selectionLocked = true
        selectionView.selectionInteractionEnabled = true
        selectionView.annotationToolActive = true
        editorHostView = selectionView
        // 禁用其余屏的选区交互，避免跨屏点击污染宿主屏编辑器几何。
        disableSelectionInteractionOnOtherScreens(keeping: selectionView)

        // 优先 panel.screen；无 window 时（测试 embed）用 displayID 匹配 NSScreen。
        let pinScreen = selectionView.window?.screen
            ?? displayID.flatMap { id in
                NSScreen.screens.first(where: { $0.displayID == id })
            }
        let encoder = outputEncoder ?? ImageOutputEncoder()
        let clipboard = clipboardWriter ?? ClipboardImageWriter()
        let editor = AnnotationEditorController(
            baseImage: image,
            document: AnnotationDocument(),
            resultRunner: resolvedResultPipeline(),
            encoder: encoder,
            clipboardWriter: clipboard,
            // 区域 / all-in-one 入口：mode=.allInOne，selection 来自选区视图矩形。
            makeResult: makeResultBuilder(
                mode: .allInOne,
                screen: pinScreen,
                selectionViewRect: selectionRect
            ),
            sourceBackingScaleFactor: pinScreen?.backingScaleFactor ?? 1,
            onComplete: { [weak self] finalImage in
                guard let self else { return }
                Self.logger.info("[SSDBG] handleCapturedImage 编辑器 onComplete(#7) 被调用，image=\(finalImage != nil)")
                self.tearDown()
                let hadCompletion = (self.onComplete != nil)
                Self.logger.info("[SSDBG] #7 调用 self.onComplete 前，self.onComplete != nil = \(hadCompletion)")
                self.onComplete?(finalImage)
                self.onComplete = nil
            }
        )
        editor.onRecordingSelection = onRecordingSelection
        editorController = editor
        editor.show(
            in: selectionView,
            selectionRect: selectionRect,
            captureRect: captureRect,
            preSnapshot: preSnapshot,
            displayID: displayID
        )
    }
}

/// 遮罩层面板子类：允许成为 key 窗口以接收键盘事件。
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 测试钩子

extension CaptureOverlayController {
    /// 测试用：枚举当前所有 overlay 面板对应的 SelectionView。
    /// 仅用于断言多屏编辑器交互禁用等内部状态。
    var selectionViewsForTesting: [SelectionView] {
        Array(selectionViews.values)
    }

    /// 测试用：当前已注入的冻屏字典（apply 后可读）。
    var screenSnapshotsForTesting: [CGDirectDisplayID: CGImage] {
        screenSnapshots
    }

    /// 测试用：是否已 tearDown（apply 守卫可读）。
    var isTornDownForTesting: Bool {
        isTornDown
    }

    /// 测试用：注册一组 SelectionView，使其进入 controller 的内部交互禁用管理范围。
    /// 直接写入 selectionViews 映射（key 用哑 panel 占位），用于多屏回归测试。
    func registerSelectionViewsForTesting(_ views: [SelectionView]) {
        for view in views {
            // 用哑 NSWindow 占位 key；测试不依赖真实 panel 行为。
            let dummy = OverlayPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            selectionViews[dummy] = view
        }
    }

    /// 测试用：模拟宿主屏选区完成并嵌入编辑器，返回嵌入的宿主 SelectionView。
    /// 内部直接调用 `handleCapturedImage`，等价于真实选区完成路径。
    @discardableResult
    func embedEditorForTesting(
        image: NSImage,
        selectionRect: NSRect,
        selectionView: SelectionView,
        captureRect: CGRect = .zero,
        preSnapshot: CGImage? = nil,
        displayID: CGDirectDisplayID? = nil
    ) -> SelectionView? {
        handleCapturedImage(
            image,
            selectionRect: selectionRect,
            selectionView: selectionView,
            captureRect: captureRect,
            preSnapshot: preSnapshot,
            displayID: displayID
        )
        return editorHostView
    }
}

