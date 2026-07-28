import AppKit

/// Full-screen, mouse-transparent red border around the active recording selection.
/// Mirrors CapCap `RecordingBorderPanel`; window is excluded from SCStream capture.
final class RecordingBorderPanel: NSPanel {
    private let borderView: RecordingBorderView
    private let targetScreen: NSScreen

    init(screen: NSScreen) {
        self.targetScreen = screen
        self.borderView = RecordingBorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar + 1
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = borderView
    }

    func setSelectionRect(_ screenRect: NSRect) {
        borderView.selectionRect = NSRect(
            x: screenRect.minX - targetScreen.frame.minX,
            y: screenRect.minY - targetScreen.frame.minY,
            width: screenRect.width,
            height: screenRect.height
        )
    }
}

private final class RecordingBorderView: NSView {
    var selectionRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              selectionRect.width > 0,
              selectionRect.height > 0
        else { return }

        let strokeWidth: CGFloat = 3
        let outerRect = selectionRect.insetBy(dx: -(strokeWidth / 2 + 1), dy: -(strokeWidth / 2 + 1))
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(strokeWidth)
        context.stroke(outerRect)
    }
}
