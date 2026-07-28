import AppKit

/// Floating recording HUD: elapsed time, pause/resume, stop, and drag handle.
/// Mirrors CapCap `RecordingHUDPanel`; uses `EditorHUD` chrome for OmniForge styling.
final class RecordingHUDPanel: NSPanel {
    var onStopRecording: (() -> Void)?
    var onPauseRecording: (() -> Void)?
    var onResumeRecording: (() -> Void)?

    private let containerView = RecordingHUDContainerView()
    private let stopButton = NSButton()
    private let pauseButton = NSButton()
    private let recordDot = NSTextField(labelWithString: "●")
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dragHandle = NSImageView()
    private(set) var isPaused = false
    fileprivate(set) var userHasDragged = false

    private let stopToolTip: String
    private let pauseToolTip: String
    private let resumeToolTip: String

    private let hudSize = NSSize(width: 164, height: 32)

    init(
        stopToolTip: String = "Stop",
        pauseToolTip: String = "Pause",
        resumeToolTip: String = "Resume"
    ) {
        self.stopToolTip = stopToolTip
        self.pauseToolTip = pauseToolTip
        self.resumeToolTip = resumeToolTip
        super.init(
            contentRect: NSRect(origin: .zero, size: hudSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar + 2
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        containerView.panel = self
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 10
        containerView.layer?.borderWidth = 0.5
        containerView.applyAppearance()
        contentView = containerView

        setupControls()
        layoutControls()
    }

    override var canBecomeKey: Bool { false }

    func update(elapsedSeconds: Int) {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        timeLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
        layoutControls()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        recordDot.textColor = paused ? .systemOrange : .systemRed
        pauseButton.toolTip = paused ? resumeToolTip : pauseToolTip
        updatePauseIcon()
    }

    func positionOnScreen(relativeTo screenRect: NSRect, screen: NSScreen?) {
        let gap: CGFloat = 8
        var origin = NSPoint(
            x: screenRect.maxX - hudSize.width - gap,
            y: screenRect.maxY + gap
        )

        if let screen {
            let visible = screen.visibleFrame
            if origin.y + hudSize.height > visible.maxY {
                origin.y = screenRect.minY - hudSize.height - gap
            }
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - hudSize.width - 4))
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - hudSize.height - 4))
        }

        setFrameOrigin(origin)
    }

    private func setupControls() {
        stopButton.bezelStyle = .regularSquare
        stopButton.isBordered = false
        stopButton.imageScaling = .scaleProportionallyDown
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: stopToolTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        stopButton.contentTintColor = .labelColor
        stopButton.toolTip = stopToolTip
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        containerView.addSubview(stopButton)

        pauseButton.bezelStyle = .regularSquare
        pauseButton.isBordered = false
        pauseButton.imageScaling = .scaleProportionallyDown
        pauseButton.contentTintColor = .labelColor
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        containerView.addSubview(pauseButton)
        updatePauseIcon()

        recordDot.font = .systemFont(ofSize: 11, weight: .bold)
        recordDot.textColor = .systemRed
        recordDot.isBezeled = false
        recordDot.drawsBackground = false
        recordDot.isEditable = false
        containerView.addSubview(recordDot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .labelColor
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        timeLabel.isEditable = false
        containerView.addSubview(timeLabel)

        dragHandle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        dragHandle.contentTintColor = .secondaryLabelColor
        dragHandle.imageScaling = .scaleProportionallyDown
        containerView.addSubview(dragHandle)
    }

    private func layoutControls() {
        let buttonSize: CGFloat = 24
        let padding: CGFloat = 6
        let height = hudSize.height

        stopButton.frame = NSRect(x: padding, y: (height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        pauseButton.frame = NSRect(
            x: stopButton.frame.maxX + 2,
            y: (height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )

        recordDot.sizeToFit()
        timeLabel.sizeToFit()
        recordDot.frame.origin = NSPoint(x: pauseButton.frame.maxX + 6, y: (height - recordDot.frame.height) / 2)
        timeLabel.frame.origin = NSPoint(x: recordDot.frame.maxX + 3, y: (height - timeLabel.frame.height) / 2)
        dragHandle.frame = NSRect(x: hudSize.width - 26, y: (height - 16) / 2, width: 20, height: 16)
    }

    private func updatePauseIcon() {
        let symbol = isPaused ? "play.fill" : "pause.fill"
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        pauseButton.toolTip = isPaused ? resumeToolTip : pauseToolTip
    }

    @objc private func stopClicked() {
        onStopRecording?()
    }

    @objc private func pauseClicked() {
        if isPaused {
            onResumeRecording?()
        } else {
            onPauseRecording?()
        }
    }
}

private final class RecordingHUDContainerView: NSView {
    weak var panel: RecordingHUDPanel?
    private var dragOffset: NSPoint = .zero
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        layer?.borderColor = EditorHUD.separator().cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isInDragZone(point) ? NSCursor.openHand.set() : NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isInDragZone(point) else { return }
        isDragging = true
        let mouse = NSEvent.mouseLocation
        let origin = panel?.frame.origin ?? .zero
        dragOffset = NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let panel else { return }
        panel.userHasDragged = true
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        let point = convert(event.locationInWindow, from: nil)
        isInDragZone(point) ? NSCursor.openHand.set() : NSCursor.arrow.set()
    }

    private func isInDragZone(_ point: NSPoint) -> Bool {
        point.x >= bounds.maxX - 32
    }
}
