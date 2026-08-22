import AppKit

// MARK: - Hint

/// Persistent "press any key to finish" hint shown centered near the top of
/// the selection during scroll capture. Own window so ScreenCaptureKit can
/// exclude it from stitched frames.
final class ScrollCaptureHintWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 8
    /// Gap between the selection's top edge and the hint pill.
    private let topInset: CGFloat = 12

    init(text: String) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        container.layer?.cornerRadius = 8

        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        container.addSubview(label)
        contentView = container
    }

    /// Size to the text and place top-center inside `selectionRect`
    /// (AppKit screen coordinates).
    func present(in selectionRect: NSRect) {
        label.sizeToFit()
        let textSize = label.frame.size
        let width = textSize.width + horizontalPadding * 2
        let height = textSize.height + verticalPadding * 2

        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        contentView?.layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        label.setFrameOrigin(NSPoint(x: horizontalPadding, y: verticalPadding))

        let origin = NSPoint(
            x: round(selectionRect.midX - width / 2),
            y: round(selectionRect.maxY - topInset - height)
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
        contentView = nil
    }
}

// MARK: - Stop control

/// Floating stop button anchored to the scroll-capture toolbar button frame.
final class ScrollCaptureControlWindow: NSPanel {
    init(buttonFrame: NSRect, onTap: @escaping () -> Void) {
        let padding: CGFloat = 6
        let windowRect = NSRect(
            x: buttonFrame.minX - padding,
            y: buttonFrame.minY - padding,
            width: buttonFrame.width + padding * 2,
            height: buttonFrame.height + padding * 2
        )

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 4
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = ScrollCaptureControlView(
            frame: NSRect(origin: .zero, size: windowRect.size),
            onTap: onTap
        )
    }

    func dismiss() {
        orderOut(nil)
        contentView = nil
    }
}

private final class ScrollCaptureControlView: NSView {
    private let onTap: () -> Void

    init(frame: NSRect, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        let button = AnnotationToolButton(
            frame: bounds.insetBy(dx: 6, dy: 6),
            symbolName: "arrow.up.and.down.text.horizontal",
            normalColor: .labelColor,
            selectedColor: EditorHUD.accentGreen
        )
        button.isSelected = true
        button.target = self
        button.action = #selector(buttonTapped)
        addSubview(button)
    }

    @objc private func buttonTapped() {
        onTap()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        EditorHUD.toolbarBackground().setFill()
        path.fill()
    }
}

// MARK: - Crop confirm

/// Floating confirm button shown during crop mode.
final class ScrollCropControlWindow: NSPanel {
    private static let windowSize = NSSize(width: 56, height: 44)

    init(onConfirm: @escaping () -> Void, toolTip: String? = nil) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 4
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = ScrollCropControlView(
            frame: NSRect(origin: .zero, size: Self.windowSize),
            onConfirm: onConfirm,
            toolTip: toolTip
        )
    }

    func positionAtBottom(of screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: round(visible.midX - size.width / 2),
            y: round(visible.minY + 36)
        ))
    }

    func dismiss() {
        orderOut(nil)
        contentView = nil
    }
}

private final class ScrollCropControlView: NSView {
    private let onConfirm: () -> Void
    private let confirmToolTip: String?

    init(frame: NSRect, onConfirm: @escaping () -> Void, toolTip: String? = nil) {
        self.onConfirm = onConfirm
        self.confirmToolTip = toolTip
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setup() {
        let button = AnnotationToolButton(
            frame: bounds.insetBy(dx: 6, dy: 6),
            symbolName: "checkmark",
            normalColor: EditorHUD.accentGreen,
            selectedColor: EditorHUD.accentGreen
        )
        button.target = self
        button.action = #selector(confirmTapped)
        if let confirmToolTip {
            button.toolTip = confirmToolTip
            button.hoverTip = confirmToolTip
        }
        addSubview(button)
    }

    @objc private func confirmTapped() {
        onConfirm()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        EditorHUD.toolbarBackground().setFill()
        path.fill()
    }
}

// MARK: - Side preview

/// Side panel showing the incrementally stitched long-screenshot preview.
final class ScrollPreviewWindow: NSPanel {
    private let imageView = NSImageView()
    private let maxPreviewWidth: CGFloat = 120
    private let maxPreviewHeight: CGFloat = 400
    private let contentInset: CGFloat = 4

    init() {
        let initialRect = NSRect(
            x: 0,
            y: 0,
            width: maxPreviewWidth + contentInset * 2,
            height: maxPreviewHeight + contentInset * 2
        )
        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let containerRect = NSRect(origin: .zero, size: initialRect.size)
        let container = NSView(frame: containerRect)
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = EditorHUD.separator().cgColor
        container.autoresizingMask = [.width, .height]

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.frame = containerRect.insetBy(dx: contentInset, dy: contentInset)
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)

        contentView = container
    }

    func updatePreview(_ image: NSImage, anchorRect: NSRect) {
        imageView.image = image
        let windowW = maxPreviewWidth + contentInset * 2
        let windowH = maxPreviewHeight + contentInset * 2

        // Position to the right of selection, or left if no room.
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        var x = anchorRect.maxX + 12
        if x + windowW > screenFrame.maxX {
            x = anchorRect.minX - windowW - 12
        }
        // Vertically align to top of selection.
        let y = anchorRect.maxY - windowH

        setFrame(NSRect(x: x, y: y, width: windowW, height: windowH), display: true)

        if !isVisible {
            orderFrontRegardless()
        }
    }

    func dismiss() {
        orderOut(nil)
        imageView.image = nil
        contentView = nil
    }
}

// MARK: - Info toast

/// Short-lived non-blocking status toast (success / guidance). Mirrors the
/// hint pill styling so scroll-capture feedback stays consistent without a
/// modal NSAlert.
final class EditorInfoToastWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 10
    private var dismissWorkItem: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        container.layer?.cornerRadius = 8

        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        container.addSubview(label)
        contentView = container
    }

    /// Present `message` near the bottom-center of `anchorScreen` (or main
    /// screen), auto-dismissing after `duration`.
    func present(
        _ message: String,
        near anchorScreen: NSScreen? = NSScreen.main,
        duration: TimeInterval = 2.0
    ) {
        dismissWorkItem?.cancel()
        label.stringValue = message
        label.sizeToFit()
        let textSize = label.frame.size
        let width = textSize.width + horizontalPadding * 2
        let height = textSize.height + verticalPadding * 2

        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        contentView?.layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        label.setFrameOrigin(NSPoint(x: horizontalPadding, y: verticalPadding))

        let visible = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: round(visible.midX - width / 2),
            y: round(visible.minY + 72)
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        orderOut(nil)
    }
}
