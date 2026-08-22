import AppKit
import CoreGraphics
import Foundation
import os.log

/// 单钉图生命周期与交互：状态全部挂在实例上。
/// 窗口形态参考 Shelf 浮动面板（borderless / floating / canJoinAllSpaces）。
@MainActor
final class PinnedScreenshotWindowController: NSObject, NSWindowDelegate {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "PinnedScreenshot")

    let id: UUID
    let createdAt: Date
    private let image: CGImage
    private let pointPixelScale: CGFloat
    private let baseResult: ScreenshotResult?
    private let pipeline: ScreenshotResultPipeline
    private let onClose: (UUID) -> Void

    private(set) var state: PinnedScreenshotState
    private(set) var isClosed = false
    /// 最近一次用户可见操作错误（右键复制/保存失败等）；成功时清空。
    private(set) var lastError: String?
    /// T15 L10n 注入（默认英文，Factory 注入运行时语言）。
    var stringsProvider: () -> Strings = { .en }
    /// 单击/触摸通知：Registry 据此选中钉图，使其成为唯一的 ESC 关闭目标。
    var onTouch: ((UUID) -> Void)?

    private var panel: NSPanel?
    private var contentView: PinnedScreenshotContentView?
    private var dragStartOrigin: CGPoint?
    private var dragStartEventLocation: CGPoint?

    init(
        id: UUID,
        image: CGImage,
        pointPixelScale: CGFloat,
        baseResult: ScreenshotResult?,
        pipeline: ScreenshotResultPipeline,
        createdAt: Date = Date(),
        initialState: PinnedScreenshotState = PinnedScreenshotState(),
        suppressesWindowDisplay: Bool = (NSClassFromString("XCTestCase") != nil),
        onClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.image = image
        self.pointPixelScale = pointPixelScale
        self.baseResult = baseResult
        self.pipeline = pipeline
        self.createdAt = createdAt
        self.state = initialState
        self.suppressesWindowDisplay = suppressesWindowDisplay
        self.onClose = onClose
        super.init()
    }

    let suppressesWindowDisplay: Bool

    var handle: PinnedScreenshotHandle {
        PinnedScreenshotHandle(
            id: id,
            createdAt: createdAt,
            isLocked: state.isLocked,
            isClickThrough: state.isClickThrough,
            opacity: state.opacity,
            scale: state.scale,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// 判断本地鼠标事件是否由当前贴图面板接收，供注册表维护 ESC 选中状态。
    func owns(_ window: NSWindow?) -> Bool {
        panel === window
    }

    /// 展示钉图；几何无效时明确失败。
    /// - Parameters:
    ///   - preferredScreenFrame: 结果所属屏（决定可见区）。
    ///   - preferredOrigin: 可选的屏幕原点（AppKit 坐标）。非 nil 时按原位钉住，
    ///     仅 clamp 到可见区，不强制居中（参照 capcap `PinLauncher.pin(image:at:)`）。
    func present(preferredScreenFrame: CGRect?, preferredOrigin: NSPoint? = nil) throws {
        guard !isClosed else {
            throw PinnedScreenshotError.alreadyClosed(id)
        }
        guard let natural = PinnedScreenshotGeometry.naturalDisplaySize(
            pixelWidth: image.width,
            pixelHeight: image.height,
            pointPixelScale: pointPixelScale
        ) else {
            throw PinnedScreenshotError.invalidGeometry
        }

        // 参照 capcap：只缩小适应屏幕，不放大（ratio ≤ 1）。
        // state.scale 初值默认为 1，故初始 displaySize = natural（自然尺寸）。
        let visible = Self.visibleFrame(preferredScreenFrame: preferredScreenFrame)
        let displaySize = CGSize(
            width: natural.width * state.scale,
            height: natural.height * state.scale
        )
        let clampedSize = PinnedScreenshotGeometry.fittedSize(for: displaySize, in: visible)
        guard clampedSize.width > 0, clampedSize.height > 0 else {
            throw PinnedScreenshotError.invalidGeometry
        }
        // 同步 scale 到缩放后尺寸（只可能 ≤ 1）
        if let synced = PinnedScreenshotGeometry.scale(
            displaySize: clampedSize,
            pixelWidth: image.width,
            pixelHeight: image.height,
            pointPixelScale: pointPixelScale
        ) {
            state.scale = synced
        }

        guard let frame = PinnedScreenshotGeometry.frameFittingVisibleArea(
            size: clampedSize,
            preferredOrigin: preferredOrigin,
            visibleFrame: visible
        ) else {
            throw PinnedScreenshotError.invalidGeometry
        }

        let panel = makePanel(frame: frame)
        let content = PinnedScreenshotContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.image = image
        content.pointPixelScale = pointPixelScale
        content.isLocked = state.isLocked
        content.alphaValue = state.opacity
        content.onDrag = { [weak self] event in
            self?.handleDrag(event)
        }
        content.onScrollWheel = { [weak self] event in
            self?.handleScroll(event)
        }
        content.onRightMouseDown = { [weak self] event in
            self?.showContextMenu(event)
        }
        content.menuProvider = { [weak self] in
            self?.buildContextMenu()
        }
        content.onDoubleClick = { [weak self] in
            self?.close()
        }
        content.onTouch = { [weak self] in
            guard let self else { return }
            self.onTouch?(self.id)
        }

        panel.contentView = content
        panel.alphaValue = 1
        content.alphaValue = state.opacity
        applyClickThrough(state.isClickThrough, to: panel)

        self.panel = panel
        self.contentView = content
        if !suppressesWindowDisplay {
            panel.orderFront(nil)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        panel?.delegate = nil
        panel?.close()
        panel = nil
        contentView = nil
        onClose(id)
    }

    // MARK: - 状态 API

    func setLocked(_ locked: Bool) {
        state.setLocked(locked)
        contentView?.isLocked = locked
        contentView?.needsDisplay = true
    }

    func setClickThrough(_ clickThrough: Bool) {
        state.setClickThrough(clickThrough)
        if let panel {
            applyClickThrough(clickThrough, to: panel)
        }
    }

    func setOpacity(_ opacity: CGFloat) {
        state.setOpacity(opacity)
        contentView?.alphaValue = state.opacity
    }

    func applyTranslation(_ delta: CGPoint) -> Bool {
        guard let applied = state.proposedTranslation(delta), let panel else { return false }
        var frame = panel.frame
        frame.origin.x += applied.x
        frame.origin.y += applied.y
        panel.setFrame(frame, display: true)
        return true
    }

    func applyScaleFactor(_ factor: CGFloat, anchor: PinnedScreenshotGeometry.ScaleAnchor = .windowCenter) -> Bool {
        guard state.proposedScale(multiplying: factor) != nil, let panel else { return false }
        guard let newFrame = PinnedScreenshotGeometry.scaledFrame(
            currentFrame: panel.frame,
            scaleFactor: factor,
            anchor: anchor
        ) else {
            return false
        }
        if let newScale = PinnedScreenshotGeometry.scale(
            displaySize: newFrame.size,
            pixelWidth: image.width,
            pixelHeight: image.height,
            pointPixelScale: pointPixelScale
        ) {
            _ = state.applyScale(newScale)
        }
        panel.setFrame(newFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: newFrame.size)
        contentView?.needsDisplay = true
        return true
    }

    // MARK: - 复制 / 保存（复用 T3 管线）

    func copyImage() throws {
        do {
            _ = try pipeline.run(result: makeResultForPipeline(), intent: .copy)
        } catch let error as ScreenshotPipelineError {
            throw PinnedScreenshotError.copyFailed(String(describing: error))
        } catch {
            throw PinnedScreenshotError.copyFailed(String(describing: error))
        }
    }

    func saveImage() throws {
        do {
            _ = try pipeline.run(result: makeResultForPipeline(), intent: .save)
        } catch let error as ScreenshotPipelineError {
            throw PinnedScreenshotError.saveFailed(String(describing: error))
        } catch {
            throw PinnedScreenshotError.saveFailed(String(describing: error))
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        panel = nil
        contentView = nil
        onClose(id)
    }

    // MARK: - Private

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        return panel
    }

    private func applyClickThrough(_ enabled: Bool, to panel: NSPanel) {
        panel.ignoresMouseEvents = enabled
    }

    private func handleDrag(_ event: NSEvent) {
        guard !state.isLocked, !state.isClickThrough, let panel else { return }
        switch event.type {
        case .leftMouseDown:
            dragStartOrigin = panel.frame.origin
            dragStartEventLocation = event.locationInWindow
            // 转全局
            dragStartEventLocation = panel.convertPoint(toScreen: event.locationInWindow)
        case .leftMouseDragged:
            guard let startOrigin = dragStartOrigin,
                  let startLoc = dragStartEventLocation else { return }
            let current = panel.convertPoint(toScreen: event.locationInWindow)
            let delta = CGPoint(x: current.x - startLoc.x, y: current.y - startLoc.y)
            guard state.proposedTranslation(delta) != nil else { return }
            var frame = panel.frame
            frame.origin = CGPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y)
            panel.setFrame(frame, display: true)
        case .leftMouseUp:
            dragStartOrigin = nil
            dragStartEventLocation = nil
        default:
            break
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard !state.isLocked, !state.isClickThrough else { return }
        // 与 AnnotationCanvasView 一致：仅用 scrollingDeltaY 判向，不做设备方向二次反转
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let factor: CGFloat = dy > 0 ? 1.08 : 1 / 1.08
        _ = applyScaleFactor(factor, anchor: .windowCenter)
    }

    private func showContextMenu(_ event: NSEvent) {
        guard !state.isClickThrough, let contentView else { return }
        guard let menu = buildContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    private func buildContextMenu() -> NSMenu? {
        guard !state.isClickThrough else { return nil }
        let strings = stringsProvider()
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: strings.screenshotPinMenuCopy, action: #selector(menuCopy), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let saveItem = NSMenuItem(title: strings.screenshotPinMenuSave, action: #selector(menuSave), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(.separator())

        let lockTitle = state.isLocked ? strings.screenshotPinMenuUnlock : strings.screenshotPinMenuLock
        let lockItem = NSMenuItem(title: lockTitle, action: #selector(menuToggleLock), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)

        let throughTitle = state.isClickThrough
            ? strings.screenshotPinMenuDisableClickThrough
            : strings.screenshotPinMenuClickThrough
        let throughItem = NSMenuItem(title: throughTitle, action: #selector(menuToggleClickThrough), keyEquivalent: "")
        throughItem.target = self
        menu.addItem(throughItem)

        // 透明度步进
        let opacityMenu = NSMenu()
        for value in [1.0, 0.8, 0.6, 0.4, 0.2] as [CGFloat] {
            let item = NSMenuItem(
                title: "\(Int(value * 100))%",
                action: #selector(menuSetOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = value
            item.state = abs(state.opacity - value) < 0.05 ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: strings.screenshotPinMenuOpacity, action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: strings.screenshotPinMenuClose, action: #selector(menuClose), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        return menu
    }

    @objc private func menuCopy() {
        do {
            try copyImage()
            lastError = nil
        } catch {
            presentUserError(error, context: "pin copy failed")
        }
    }

    @objc private func menuSave() {
        do {
            try saveImage()
            lastError = nil
        } catch {
            presentUserError(error, context: "pin save failed")
        }
    }

    /// 右键菜单等用户操作失败：可观察 lastError + 系统蜂鸣，禁止仅日志静默。
    private func presentUserError(_ error: Error, context: String) {
        let message = String(describing: error)
        lastError = message
        Self.logger.error("\(context, privacy: .public): \(message, privacy: .public)")
        NSSound.beep()
    }

    @objc private func menuToggleLock() {
        setLocked(!state.isLocked)
    }

    @objc private func menuToggleClickThrough() {
        setClickThrough(!state.isClickThrough)
    }

    @objc private func menuSetOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        setOpacity(value)
    }

    @objc private func menuClose() {
        close()
    }

    private func makeResultForPipeline() throws -> ScreenshotResult {
        if let baseResult {
            return try ScreenshotResult(
                mode: baseResult.mode,
                targetScreen: baseResult.targetScreen,
                selection: baseResult.selection,
                timestamp: baseResult.timestamp,
                pixelImage: image,
                windowInfo: baseResult.windowInfo
            )
        }
        let screen = CaptureTargetScreen(
            displayID: 0,
            frameInAppKitPoints: panel?.screen?.frame
                ?? NSScreen.main?.frame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
            pointPixelScale: pointPixelScale
        )
        return try ScreenshotResult(
            mode: .fullScreen,
            targetScreen: screen,
            selection: nil,
            timestamp: createdAt,
            pixelImage: image,
            windowInfo: nil
        )
    }

    /// 可见区域：优先结果所属屏，否则鼠标所在屏。
    private static func visibleFrame(preferredScreenFrame: CGRect?) -> CGRect {
        if let preferred = preferredScreenFrame,
           let match = NSScreen.screens.first(where: { $0.frame.equalTo(preferred) }) {
            return match.visibleFrame
        }
        if let preferred = preferredScreenFrame {
            // displayID/frame 可能因配置变化不完全相等：取含中心点的屏
            let center = CGPoint(x: preferred.midX, y: preferred.midY)
            if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return match.visibleFrame
            }
        }
        return screenWithMouse.visibleFrame
    }

    private static var screenWithMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

// MARK: - 内容视图

/// 绘制截图 + 锁定角标；处理拖动/滚轮/右键。
final class PinnedScreenshotContentView: NSView {
    var image: CGImage?
    var pointPixelScale: CGFloat = 2
    var isLocked: Bool = false

    var onDrag: ((NSEvent) -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// 双击关闭回调
    var onDoubleClick: (() -> Void)?
    /// 单击/触摸：用于选中钉图（ESC 关闭目标）
    var onTouch: (() -> Void)?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }

        // 与冻屏 / 标注预览一致：NSImage 负责 CGImage → AppKit 方向。
        // 禁止对正确方向的 CGImage 再做 translate + scale(y:-1)，否则钉图上下翻转。
        let nsImage = NSImage(cgImage: image, size: bounds.size)
        nsImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)

        // 细边框
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        (isLocked ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.55)).setStroke()
        border.lineWidth = isLocked ? 2 : 1
        border.stroke()

        // 锁定明确指示（角标），禁止仅靠行为推断
        if isLocked {
            let badgeSize: CGFloat = 18
            let badge = NSRect(
                x: bounds.maxX - badgeSize - 6,
                y: bounds.maxY - badgeSize - 6,
                width: badgeSize,
                height: badgeSize
            )
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white
            ]
            let str = "L" as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(
                at: CGPoint(
                    x: badge.midX - size.width / 2,
                    y: badge.midY - size.height / 2
                ),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 双击直接关闭；单击先标记最近交互，再进入拖拽流程
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        onTouch?()
        onDrag?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onTouch?()
        onRightMouseDown?(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
