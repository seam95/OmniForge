import AppKit

// MARK: - Scroll capture HUD

/// 长截图会话 HUD：信息条（标题 · 当前拼接尺寸）+ 停止按钮。
/// 独立 nonactivatingPanel 接收鼠标（宿主遮罩 ignoresMouseEvents），点击不夺焦。
final class ScrollCaptureHUDView: NSView {
    private let infoLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton()
    private let baseTitle: String

    var onStop: (() -> Void)?

    init(title: String, stopTitle: String) {
        self.baseTitle = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor

        infoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = .labelColor
        infoLabel.isEditable = false
        infoLabel.isBordered = false
        infoLabel.drawsBackground = false
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = title
        // labelWithString 后必须 sizeToFit 才能得到真实文本宽度，
        // 否则初始布局按零宽排布、后续 update 增宽会溢出窗口。
        infoLabel.sizeToFit()
        addSubview(infoLabel)

        stopButton.title = stopTitle
        stopButton.bezelStyle = .recessed
        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        stopButton.layer?.cornerRadius = 12
        stopButton.contentTintColor = .white
        stopButton.font = .systemFont(ofSize: 12, weight: .semibold)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        addSubview(stopButton)

        layoutSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 更新进度信息（当前拼接尺寸）。
    func update(pixelSize: CGSize, backingScale: CGFloat) {
        let pointWidth = Int((pixelSize.width / max(1, backingScale)).rounded())
        let pointHeight = Int((pixelSize.height / max(1, backingScale)).rounded())
        if pointWidth > 0, pointHeight > 0 {
            infoLabel.stringValue = "\(baseTitle) · \(pointWidth)×\(pointHeight)"
        }
        infoLabel.sizeToFit()
        layoutSubviews()
    }

    func layoutSubviews() {
        let pad: CGFloat = 8
        let stopButtonWidth: CGFloat = 56
        let buttonHeight: CGFloat = 24
        let barHeight: CGFloat = 36

        let infoWidth = infoLabel.frame.width
        let totalWidth = pad + infoWidth + pad + stopButtonWidth + pad

        frame.size = NSSize(width: totalWidth, height: barHeight)

        let infoHeight = infoLabel.frame.height
        infoLabel.frame.origin = NSPoint(x: pad, y: (barHeight - infoHeight) / 2)

        stopButton.frame = NSRect(
            x: totalWidth - pad - stopButtonWidth,
            y: (barHeight - buttonHeight) / 2,
            width: stopButtonWidth,
            height: buttonHeight
        )

        invalidateIntrinsicContentSize()
    }

    @objc private func stopClicked() {
        onStop?()
    }
}

/// 承载长截图 HUD 的独立面板。高于编辑器遮罩与预览面板；不可成为 key
/// （点击按钮不夺走底层页面的焦点）。窗口尺寸始终跟随 HUD 内容，
/// 每次进度更新后相对选区重摆（内容变宽不会溢出裁切按钮）。
final class ScrollCaptureHUDWindow: NSPanel {
    let hudView: ScrollCaptureHUDView
    private var selectionScreenRect: NSRect?
    private var targetScreen: NSScreen?

    init(title: String, stopTitle: String, onStop: @escaping () -> Void) {
        hudView = ScrollCaptureHUDView(title: title, stopTitle: stopTitle)
        hudView.onStop = onStop

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .screenSaver + 4
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView()
        container.addSubview(hudView)
        contentView = container
    }

    override var canBecomeKey: Bool { false }

    /// 摆到选区下方居中；下方放不下移到选区上方；水平方向夹在屏内。
    func position(relativeTo selectionScreenRect: NSRect, on screen: NSScreen) {
        self.selectionScreenRect = selectionScreenRect
        targetScreen = screen
        layoutAroundSelection()
        orderFrontRegardless()
    }

    /// 按当前 HUD 内容尺寸重设窗口并相对选区重摆。
    private func layoutAroundSelection() {
        guard let selectionScreenRect, let targetScreen else { return }

        hudView.layoutSubviews()
        let hudSize = hudView.frame.size
        let visible = targetScreen.visibleFrame

        var barX = selectionScreenRect.midX - hudSize.width / 2
        var barY = selectionScreenRect.minY - hudSize.height - 6
        if barY < visible.minY + 4 {
            barY = selectionScreenRect.maxY + 6
        }
        barX = max(visible.minX + 4, min(barX, visible.maxX - hudSize.width - 4))

        setFrame(
            NSRect(x: barX, y: barY, width: hudSize.width, height: hudSize.height),
            display: true
        )
        hudView.frame.origin = .zero
        contentView?.frame = NSRect(origin: .zero, size: hudSize)
    }

    /// 进度更新：内容尺寸变化后窗口必须跟随，否则右侧按钮会被 contentRect 裁掉。
    func update(pixelSize: CGSize, backingScale: CGFloat) {
        hudView.update(pixelSize: pixelSize, backingScale: backingScale)
        layoutAroundSelection()
    }

    func dismiss() {
        orderOut(nil)
        selectionScreenRect = nil
        targetScreen = nil
        contentView = nil
    }
}

// MARK: - Side preview

/// 长截图侧边实时预览：固定 200pt 宽，出现在选区右侧（空间不足换左侧，
/// 两侧都不足则不创建）；底边对齐选区底边、向上生长，贴屏顶按剩余高度收缩。
final class ScrollPreviewWindow: NSPanel {
    private let imageView = NSImageView()
    private let captureRect: NSRect
    private let targetScreen: NSScreen
    private let previewWidth: CGFloat = 200
    private let margin: CGFloat = 12
    private let minHeight: CGFloat = 100
    /// 选区描边（2.5pt）居中于边缘，可见底线低于 minY 约 1.25pt。
    private let selectionBorderOutset: CGFloat = 1.25

    private enum Side {
        case left, right
    }

    private let side: Side

    init?(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.targetScreen = screen

        let spaceLeft = captureRect.minX - screen.frame.minX
        let spaceRight = screen.frame.maxX - captureRect.maxX
        let needed = previewWidth + margin * 2

        if spaceRight >= needed {
            side = .right
        } else if spaceLeft >= needed {
            side = .left
        } else {
            return nil
        }

        let x: CGFloat
        switch side {
        case .right: x = captureRect.maxX + margin
        case .left: x = captureRect.minX - margin - previewWidth
        }
        let frame = NSRect(
            x: x,
            y: captureRect.minY - selectionBorderOutset,
            width: previewWidth,
            height: minHeight
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 纯图片 + 圆角容器，无附加 chrome。
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = EditorHUD.toolbarBackground().cgColor
        container.autoresizingMask = [.width, .height]

        imageView.frame = container.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        container.addSubview(imageView)
        contentView = container
    }

    /// 用最新拼接图更新预览：底锚选区底边、按纵横比长高，触屏顶收缩。
    func updatePreview(_ image: NSImage) {
        imageView.image = image

        let visible = targetScreen.visibleFrame
        let x: CGFloat
        switch side {
        case .right: x = captureRect.maxX + margin
        case .left: x = captureRect.minX - margin - previewWidth
        }

        let anchorBottom = captureRect.minY - selectionBorderOutset
        let ceilingY = visible.maxY - 20
        let availableHeight = max(minHeight, ceilingY - anchorBottom)

        let imageAspect = image.size.height / max(1, image.size.width)
        let contentWidth = previewWidth - 8
        let desiredHeight = contentWidth * imageAspect + 8

        let panelHeight = min(desiredHeight, availableHeight)
        let panelBottom = anchorBottom + panelHeight <= ceilingY
            ? anchorBottom
            : ceilingY - panelHeight

        setFrame(
            NSRect(x: x, y: panelBottom, width: previewWidth, height: panelHeight),
            display: true
        )

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
/// HUD styling so scroll-capture feedback stays consistent without a modal
/// NSAlert.
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
