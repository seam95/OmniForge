import AppKit
import SwiftUI

/// Transparent strip that moves the whole panel when dragged. Used over the
/// header and empty shelf space; tiles stay free to start item drags.
struct WindowMoveHandle: NSViewRepresentable {
    var acceptsDrops = false

    func makeNSView(context: Context) -> ShelfPanelMoveView {
        let view = ShelfPanelMoveView()
        view.acceptsDrops = acceptsDrops
        return view
    }

    func updateNSView(_ nsView: ShelfPanelMoveView, context: Context) {
        nsView.acceptsDrops = acceptsDrops
    }
}

class ShelfPanelMoveView: NSView {
    var acceptsDrops = false {
        didSet { syncDraggedTypes() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        syncDraggedTypes()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let shelf = ShelfService.activeForUI else { return }
        shelf.beginInteraction()
        defer { shelf.endInteraction() }
        window?.performDrag(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dropOperation(for: sender)
        ShelfService.activeForUI?.setDropTargeted(operation != [])
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dropOperation(for: sender)
        ShelfService.activeForUI?.setDropTargeted(operation != [])
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        ShelfService.activeForUI?.setDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let shelf = ShelfService.activeForUI else { return false }
        let accepted = acceptsDrops && shelf.accept(pasteboard: sender.draggingPasteboard)
        shelf.setDropTargeted(false)
        return accepted
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        ShelfService.activeForUI?.setDropTargeted(false)
    }

    private func syncDraggedTypes() {
        unregisterDraggedTypes()
        if acceptsDrops {
            registerForDraggedTypes(ShelfService.tileDropTypes)
        }
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let shelf = ShelfService.activeForUI,
              acceptsDrops,
              !shelf.isInternalDragActive,
              shelf.canAcceptPasteboard(sender.draggingPasteboard) else {
            return []
        }
        return .copy
    }
}

/// AppKit item tiles: multi-select drag-out, merge onto tiles, file context menus.
struct ShelfTilesView: NSViewRepresentable {
    var items: [ShelfService.Item]
    var selection: Set<UUID>
    var expandedBatches: Set<UUID>

    static let tileSize = NSSize(width: ShelfChrome.tileSize.width, height: ShelfChrome.tileSize.height)
    static let spacing: CGFloat = 8
    static let inset: CGFloat = 2

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.drawsBackground = false
        let document = FlippedView()
        document.acceptsDrops = true
        scroll.documentView = document
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView else { return }
        document.subviews.forEach { $0.removeFromSuperview() }

        let tile = Self.tileSize
        let inset = Self.inset
        let contentWidth = max(scroll.contentSize.width, 276)
        let columnStride = tile.width + Self.spacing
        let rowStride = tile.height + Self.spacing
        let columns = max(1, Int((contentWidth - inset * 2 + Self.spacing) / columnStride))
        let rows = max(1, Int(ceil(Double(items.count) / Double(columns))))

        for (index, item) in items.enumerated() {
            let column = index % columns
            let row = index / columns
            let view = ShelfTileView(item: item,
                                     isSelected: selection.contains(item.id),
                                     isExpanded: expandedBatches.contains(item.id))
            view.frame = NSRect(x: inset + CGFloat(column) * columnStride,
                                y: inset + CGFloat(row) * rowStride,
                                width: tile.width,
                                height: tile.height)
            document.addSubview(view)
        }
        let contentHeight = inset * 2 + CGFloat(rows) * tile.height + CGFloat(max(0, rows - 1)) * Self.spacing
        scroll.hasVerticalScroller = contentHeight > scroll.contentSize.height + 1
        document.frame = NSRect(x: 0,
                                y: 0,
                                width: contentWidth,
                                height: max(contentHeight, scroll.contentSize.height))
    }

    private final class FlippedView: ShelfPanelMoveView {
        override var isFlipped: Bool { true }
    }
}

/// One tile. Click toggles selection; drag starts multi-select drag; successful
/// external drop removes tiles when removeAfterDrop is on.
final class ShelfTileView: NSView, NSDraggingSource {
    private let item: ShelfService.Item
    private let isSelected: Bool
    private let isExpanded: Bool
    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false
    private var draggedIDs: [UUID] = []
    private var isDropTargeted = false
    private var closeButton: NSButton!
    private var expandButton: NSButton?

    init(item: ShelfService.Item, isSelected: Bool, isExpanded: Bool) {
        self.item = item
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        super.init(frame: NSRect(origin: .zero, size: ShelfTilesView.tileSize))
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        syncChrome()
        registerForDraggedTypes(ShelfService.tileDropTypes)
        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func syncChrome() {
        if isDropTargeted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        } else if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
            layer?.borderWidth = 0.6
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    private func setDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        isDropTargeted = targeted
        syncChrome()
    }

    private func buildSubviews() {
        if item.isBatch { addStackBackplates() }

        let iconWell = NSView(frame: NSRect(x: 8, y: 8, width: 60, height: 48))
        iconWell.wantsLayer = true
        iconWell.layer?.cornerRadius = 9
        iconWell.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        addSubview(iconWell)

        let imageView = NSImageView(frame: iconWell.bounds.insetBy(dx: item.isImage ? 3 : 12,
                                                                   dy: item.isImage ? 3 : 7))
        imageView.image = item.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        iconWell.addSubview(imageView)

        if item.isBatch {
            let badge = NSTextField(labelWithString: "\(item.leafCount)")
            badge.frame = NSRect(x: 48, y: 38, width: 20, height: 15)
            badge.font = .systemFont(ofSize: 9, weight: .bold)
            badge.alignment = .center
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 7.5
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            addSubview(badge)

            let expand = NSButton(frame: NSRect(x: 5, y: 5, width: 16, height: 16))
            expand.image = NSImage(systemSymbolName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill",
                                   accessibilityDescription: nil)
            expand.isBordered = false
            expand.bezelStyle = .regularSquare
            expand.imagePosition = .imageOnly
            expand.contentTintColor = .secondaryLabelColor
            expand.target = self
            expand.action = #selector(toggleBatchExpansion)
            expandButton = expand
            addSubview(expand)
        }

        let label = NSTextField(labelWithString: item.title)
        label.frame = NSRect(x: 4, y: 58, width: 68, height: 26)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.textColor = .labelColor
        addSubview(label)

        if isSelected {
            let badgeY: CGFloat = item.isBatch ? 22 : 5
            let badge = NSImageView(frame: NSRect(x: 5, y: badgeY, width: 15, height: 15))
            badge.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            badge.contentTintColor = .controlAccentColor
            addSubview(badge)
        }

        closeButton = NSButton(frame: NSRect(x: 55, y: 5, width: 16, height: 16))
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(removeSelf)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    private func addStackBackplates() {
        for (index, offset) in [2, 1].enumerated() {
            let view = NSView(frame: NSRect(x: 8 + CGFloat(offset) * 2.5,
                                           y: 8 + CGFloat(offset) * 2.5,
                                           width: 60,
                                           height: 48))
            view.wantsLayer = true
            view.layer?.cornerRadius = 9
            view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(index == 0 ? 0.03 : 0.045).cgColor
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            addSubview(view)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let shelf = ShelfService.activeForUI else { return nil }
        shelf.noteInteraction()
        let urls = shelf.fileURLsForActions(startingAt: item)
        guard !urls.isEmpty else { return nil }

        let strings = L10n().s
        let menu = NSMenu()
        let open = NSMenuItem(title: strings.shelfActionOpen,
                              action: #selector(openFiles),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let openWith = NSMenuItem(title: strings.shelfActionOpenWith,
                                  action: nil,
                                  keyEquivalent: "")
        let applications = commonApplications(for: urls)
        if applications.isEmpty {
            openWith.isEnabled = false
        } else {
            let submenu = NSMenu(title: strings.shelfActionOpenWith)
            for applicationURL in applications.prefix(40) {
                let entry = NSMenuItem(title: FileManager.default.displayName(atPath: applicationURL.path),
                                       action: #selector(openFilesWithApplication(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.representedObject = applicationURL
                let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                submenu.addItem(entry)
            }
            openWith.submenu = submenu
        }
        menu.addItem(openWith)

        let airDrop = NSMenuItem(title: strings.shelfActionAirDrop,
                                 action: #selector(shareWithAirDrop),
                                 keyEquivalent: "")
        airDrop.target = self
        airDrop.isEnabled = NSSharingService(named: .sendViaAirDrop) != nil
        menu.addItem(airDrop)
        menu.addItem(.separator())

        let reveal = NSMenuItem(title: strings.shelfActionReveal,
                                action: #selector(revealFiles),
                                keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        ShelfService.activeForUI?.noteInteraction()
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag else { return }
        let point = event.locationInWindow
        if hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 {
            didDrag = true
            beginItemDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !didDrag, let shelf = ShelfService.activeForUI else { return }
        if item.isBatch, event.clickCount >= 2 {
            shelf.toggleBatchExpansion(item.id)
        } else {
            shelf.toggleSelection(item.id)
        }
    }

    @objc private func removeSelf() {
        ShelfService.activeForUI?.removeItem(item.id)
    }

    @objc private func toggleBatchExpansion() {
        ShelfService.activeForUI?.toggleBatchExpansion(item.id)
    }

    @objc private func openFiles() {
        guard let shelf = ShelfService.activeForUI else { return }
        for url in shelf.fileURLsForActions(startingAt: item) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFilesWithApplication(_ sender: NSMenuItem) {
        guard let shelf = ShelfService.activeForUI,
              let applicationURL = sender.representedObject as? URL else { return }
        let urls = shelf.fileURLsForActions(startingAt: item)
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls,
                                withApplicationAt: applicationURL,
                                configuration: configuration)
    }

    @objc private func shareWithAirDrop() {
        guard let shelf = ShelfService.activeForUI else { return }
        let urls = shelf.fileURLsForActions(startingAt: item)
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    @objc private func revealFiles() {
        guard let shelf = ShelfService.activeForUI else { return }
        let urls = shelf.fileURLsForActions(startingAt: item)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func commonApplications(for urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        var common = Set(NSWorkspace.shared.urlsForApplications(toOpen: first))
        for url in urls.dropFirst() {
            common.formIntersection(NSWorkspace.shared.urlsForApplications(toOpen: url))
        }
        return common.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted {
                FileManager.default.displayName(atPath: $0.path)
                    .localizedCaseInsensitiveCompare(
                        FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
            }
    }

    private func beginItemDrag(with event: NSEvent) {
        guard let shelf = ShelfService.activeForUI else { return }
        let candidates = shelf.selection.contains(item.id) ? shelf.selectedItems() : [item]
        let dragged = shelf.dragItems(for: candidates)
        guard !dragged.isEmpty else { return }
        draggedIDs = dragged.map(\.id)

        let draggingItems: [NSDraggingItem] = dragged.map { entry in
            let draggingItem = NSDraggingItem(pasteboardWriter: shelf.pasteboardWriter(for: entry))
            draggingItem.setDraggingFrame(bounds, contents: entry.icon)
            return draggingItem
        }
        shelf.beginInternalDrag(ids: draggedIDs)
        shelf.beginInteraction()
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        ShelfService.activeForUI?.sourceOperationMask(for: context) ?? .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async {
            ShelfService.activeForUI?.completeInternalDrag(dropAccepted: operation != [])
        }
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = mergeOperation(for: sender)
        setDropTargeted(operation != [])
        if operation != [] { ShelfService.activeForUI?.noteInteraction() }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = mergeOperation(for: sender)
        setDropTargeted(operation != [])
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ShelfService.activeForUI?.canMergePasteboard(sender.draggingPasteboard, into: item.id) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let merged = ShelfService.activeForUI?.mergePasteboard(sender.draggingPasteboard, into: item.id) ?? false
        setDropTargeted(false)
        return merged
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropTargeted(false)
    }

    private func mergeOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let shelf = ShelfService.activeForUI,
              shelf.canMergePasteboard(sender.draggingPasteboard, into: item.id) else {
            return []
        }
        return shelf.isInternalDragActive ? .move : .copy
    }
}
