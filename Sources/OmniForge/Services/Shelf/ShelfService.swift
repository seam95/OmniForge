import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// Preference-driven shelf state machine: items, selection, pasteboard accept/merge,
/// internal drag completion, floating panel, docked drop zone, hotkey, and shake/drag monitor.
@MainActor
final class ShelfService: ObservableObject {
    /// Weak pointer for AppKit tile / move-handle callbacks (no production singleton).
    /// Set while a floating or docked panel hosts this service; tests may leave it nil.
    private(set) static weak var activeForUI: ShelfService?
    struct Item: Identifiable, Equatable {
        let id: UUID
        indirect enum Payload: Equatable {
            case file(URL)
            case text(String)
            case link(URL)
            case batch([Item])
        }
        let payload: Payload
        let title: String
        let icon: NSImage
        let isImage: Bool

        init(id: UUID = UUID(), payload: Payload, title: String, icon: NSImage, isImage: Bool) {
            self.id = id
            self.payload = payload
            self.title = title
            self.icon = icon
            self.isImage = isImage
        }

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }

        var isBatch: Bool {
            if case .batch = payload { return true }
            return false
        }

        var batchItems: [Item] {
            if case let .batch(items) = payload { return items }
            return []
        }

        var leafCount: Int {
            switch payload {
            case .file, .text, .link: return 1
            case let .batch(items): return items.reduce(0) { $0 + $1.leafCount }
            }
        }
    }

    @Published private(set) var items: [Item] = [] {
        didSet {
            scheduleRefit()
            schedulePersist()
            // Emptying the shelf (removing or dragging out the last item) always
            // dismisses the docked shelf; only an explicit open holds an empty
            // one, and that never runs through here.
            if items.isEmpty { dockedForcedOpen = false }
            scheduleDockedSync()
        }
    }
    @Published private(set) var selection: Set<UUID> = []
    @Published private(set) var expandedBatches: Set<UUID> = []
    /// Session-only: keep the floating shelf open while working; not persisted.
    @Published private(set) var isPinned = false
    @Published private(set) var automaticExclusions: [String] = []
    @Published private(set) var dropTargeted = false
    /// True when KeyboardShortcuts could not apply the configured shelf shortcut.
    
    /// Number of times `syncWithPreferences()` has run (tests / diagnostics).
    private(set) var syncWithPreferencesCallCount = 0
    /// True after the first restore has landed on the main actor.
    private(set) var restoreCompleted = false

    private let userDefaults: UserDefaults
    private let featureAvailable: () -> Bool
    private let fileManager: FileManager
    private let storeDirectory: URL
    private let tempDir: URL
    private let persistQueue: DispatchQueue
    /// 外观偏好注入（组合根接线；nil=未接线，窗口跟随系统）。
    weak var appearance: AppearanceSettings?

    private var persistScheduled = false
    private var activeInternalDragIDs: [UUID] = []
    private var internalDragWasMerged = false
    private var interactionDepth = 0

    // MARK: Hotkey
    private var isHotkeyListening = false
    private var hasRegisteredHotkeyOnKeyUpHandler = false
    private var registeredHotkey: HotkeyDefinition?

    // MARK: Drag / shake monitor
    private var mouseMonitor: Any?
    private var shakeSamples: [ShelfShakeSample] = []
    private var lastSummon: TimeInterval = 0
    /// Drag-pasteboard state captured at mouse-down. Finder bumps the change
    /// count after this point; Dock stacks can publish the drag contents first.
    private var dragPasteboardBaseline = DragPasteboardSnapshot.empty
    private var dragBeganInDock = false
    private var dragSourceBundleIdentifier: String?

    private struct DragPasteboardSnapshot {
        let changeCount: Int
        let hasDroppableContent: Bool

        static let empty = DragPasteboardSnapshot(changeCount: 0, hasDroppableContent: false)
    }

    // MARK: Panel state
    private var panel: NSPanel?
    private let autoHideDelay: TimeInterval = 5
    private let autoHideFadeDuration: TimeInterval = 0.22
    private var autoHideTimer: Timer?
    private var autoHideFadeTimer: Timer?
    private var autoHideFadeStart: Date?
    private var pointerInsidePanel = false

    // MARK: Docked shelf (under the menu bar icon)
    /// Screen frame of the app's menu bar icon, set by AppCompositionRoot.
    var statusItemFrameProvider: (() -> NSRect?)?
    /// The shelf docked under the menu bar icon. Stays put while the shelf has
    /// items and only shrinks to a pill or grows back to the full card in place.
    private var dockedPanel: NSPanel?
    /// Collapsed means the small pill; expanded means the full card.
    @Published private(set) var dockedCollapsed = true
    @Published private(set) var dockedDragActive = false
    /// During a drag the card only opens once the pointer comes near.
    @Published private(set) var dockedProximate = false
    /// A brief green tick after a drop lands, shown on the pill.
    @Published private(set) var dockedJustCaught = false
    private var dockedFlashWork: DispatchWorkItem?
    private var dockedEndWork: DispatchWorkItem?
    /// Watches the physical mouse button while a drag holds the docked shelf up.
    private var dockedWatchdog: Timer?
    /// Set when an empty shelf is opened on purpose so it shows with nothing in it.
    private var dockedForcedOpen = false

    var isVisible: Bool { panel?.isVisible == true }

    /// Whether the global mouse monitor is currently installed (tests / diagnostics).
    var isDragMonitorActiveForTesting: Bool { mouseMonitor != nil }
    /// Whether the shelf hotkey handler is currently listening (tests / diagnostics).
    var isHotkeyListeningForTesting: Bool { isHotkeyListening }

    /// Default production store: Application Support/<bundleId>/ShelfFiles.
    private static func defaultStoreDirectory(fileManager: FileManager = .default) -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.omniforge.app"
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let target = base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("ShelfFiles", isDirectory: true)
        // 一次性迁移：老版本 Shelf 数据位于 `app.inputlock/ShelfFiles`，改名后搬迁到新 bundle id 目录。
        let legacy = base
            .appendingPathComponent("app.inputlock", isDirectory: true)
            .appendingPathComponent("ShelfFiles", isDirectory: true)
        LegacyDataMigrator.migrateDirectory(from: legacy, to: target)
        return target
    }

    init(
        userDefaults: UserDefaults = .standard,
        storeDirectory: URL? = nil,
        fileManager: FileManager = .default,
        persistQueue: DispatchQueue = DispatchQueue(label: "com.omniforge.shelf-persist", qos: .utility),
        featureAvailable: @escaping () -> Bool = {
            MainActor.assumeIsolated { FeatureRuntime.shared.isAvailable(.shelf) }
        }
    ) {
        self.userDefaults = userDefaults
        self.featureAvailable = featureAvailable
        self.fileManager = fileManager
        self.persistQueue = persistQueue
        self.storeDirectory = storeDirectory ?? Self.defaultStoreDirectory(fileManager: fileManager)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.omniforge.app"
        self.tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("OmniForgeShelf", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        try? fileManager.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.storeDirectory, withIntermediateDirectories: true)

        automaticExclusions = Defaults.sanitizedBundleIdentifierList(
            userDefaults.stringArray(forKey: UserDefaultsKeys.shelfAutomaticExclusions) ?? [])
        restoreItems()
    }

    deinit {
        // Drop the global mouse monitor if this instance registered one.
        // Hotkey onKeyUp is process-wide and gated by isHotkeyListening.
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    var itemCount: Int { items.reduce(0) { $0 + $1.leafCount } }
    var visibleItems: [Item] { visibleItems(in: items) }

    var isInternalDragActive: Bool {
        !activeInternalDragIDs.isEmpty
    }

    static let tileDropTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string,
        .tiff,
        .png,
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("NSURLPboardType"),
        NSPasteboard.PasteboardType(UTType.fileURL.identifier),
        NSPasteboard.PasteboardType(UTType.image.identifier),
        NSPasteboard.PasteboardType(UTType.url.identifier),
        NSPasteboard.PasteboardType(UTType.text.identifier),
        NSPasteboard.PasteboardType(UTType.plainText.identifier),
    ]

    // MARK: - Lifecycle

    func syncWithPreferences() {
        syncWithPreferencesCallCount += 1
        reloadAutomaticExclusions()
        let enabled = featureAvailable()
            && userDefaults.bool(forKey: UserDefaultsKeys.shelfEnabled)
        if enabled {
            syncHotkey()
            syncDragMonitor()
        } else {
            unregisterHotkey()
            stopDragMonitor()
            hide()
            hideDocked()
        }
        syncDockedShelf()
    }

    /// Re-reads the sub-preferences that need the global drag monitor (shake to
    /// open and the docked shelf); the monitor lives only while the shelf is on
    /// and at least one of them wants it.
    func syncDragMonitor() {
        let wanted = userDefaults.bool(forKey: UserDefaultsKeys.shelfEnabled)
            && (userDefaults.bool(forKey: UserDefaultsKeys.shelfShakeToOpen)
                || userDefaults.bool(forKey: UserDefaultsKeys.shelfDropZoneEnabled))
        if wanted { startDragMonitor() } else { stopDragMonitor() }
        syncDockedShelf()
    }

    // MARK: - Triggers

    func syncHotkey() {
        let wanted = featureAvailable()
            && userDefaults.bool(forKey: UserDefaultsKeys.shelfEnabled)
            && userDefaults.bool(forKey: UserDefaultsKeys.shelfShortcutEnabled)
        if wanted { registerHotkey() } else { unregisterHotkey() }
    }

    /// Current shelf shortcut (for Settings display).
    var hotkey: HotkeyDefinition {
        Self.loadShelfHotkey(from: userDefaults)
    }

    /// Persist a recorder change and re-register when the shortcut is enabled.
    func handleRecorderChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let definition = HotkeyDefinition(shortcut: shortcut) else {
            // Invalid / cleared recording — restore the last persisted binding in the recorder UI.
            KeyboardShortcuts.setShortcut(hotkey.keyboardShortcut, for: .shelfHotkey)
            return
        }
        userDefaults.set(definition.keyCode, forKey: UserDefaultsKeys.shelfHotkeyKeyCode)
        userDefaults.set(definition.modifiers.rawValue, forKey: UserDefaultsKeys.shelfHotkeyModifiers)
        objectWillChange.send()
        syncHotkey()
    }

    private func registerHotkey() {
        let hotkey = Self.loadShelfHotkey(from: userDefaults)
        KeyboardShortcuts.setShortcut(hotkey.keyboardShortcut, for: .shelfHotkey)
        registeredHotkey = hotkey
        isHotkeyListening = true

        guard !hasRegisteredHotkeyOnKeyUpHandler else { return }
        KeyboardShortcuts.onKeyUp(for: .shelfHotkey) { [weak self] in
            Task { @MainActor in
                guard let self, self.isHotkeyListening else { return }
                self.toggle()
            }
        }
        hasRegisteredHotkeyOnKeyUpHandler = true
    }

    private func unregisterHotkey() {
        // Match ClipboardHotkeyManager: keep the KeyboardShortcuts registration
        // (so Settings recorder still shows the binding) but ignore callbacks
        // via isHotkeyListening until preferences re-enable the shelf shortcut.
        isHotkeyListening = false
        registeredHotkey = nil
        // Keep the recorder showing the configured binding even when disabled.
        KeyboardShortcuts.setShortcut(
            Self.loadShelfHotkey(from: userDefaults).keyboardShortcut,
            for: .shelfHotkey
        )
    }

    private static func loadShelfHotkey(from userDefaults: UserDefaults) -> HotkeyDefinition {
        guard userDefaults.object(forKey: UserDefaultsKeys.shelfHotkeyKeyCode) != nil,
              userDefaults.object(forKey: UserDefaultsKeys.shelfHotkeyModifiers) != nil else {
            return .defaultShelf
        }
        let keyCode = userDefaults.integer(forKey: UserDefaultsKeys.shelfHotkeyKeyCode)
        let modifiersRaw = userDefaults.integer(forKey: UserDefaultsKeys.shelfHotkeyModifiers)
        return HotkeyDefinition(keyCode: keyCode, modifiers: HotkeyModifiers(rawValue: modifiersRaw))
    }

    private func startDragMonitor() {
        guard mouseMonitor == nil else { return }
        dragPasteboardBaseline = dragPasteboardSnapshot()
        dragBeganInDock = false
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalMouseEvent(event)
            }
        }
    }

    private func stopDragMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        shakeSamples.removeAll()
        dragSourceBundleIdentifier = nil
        dragBeganInDock = false
        dockedWatchdog?.invalidate()
        dockedWatchdog = nil
        dockedEndWork?.cancel()
        dockedEndWork = nil
        dockedDragActive = false
        dockedProximate = false
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Capture the drag pasteboard before any drag starts. Finder
            // changes it after this; Dock stacks can publish the drag
            // contents first.
            dragPasteboardBaseline = dragPasteboardSnapshot()
            dragBeganInDock = eventBelongsToDock(event)
            dragSourceBundleIdentifier = sourceBundleIdentifier(for: event)
            shakeSamples.removeAll()
        case .leftMouseUp:
            endDockedDrag()
        default:
            dragBeganInDock = dragBeganInDock || eventBelongsToDock(event)
            if userDefaults.bool(forKey: UserDefaultsKeys.shelfShakeToOpen) {
                handleDrag(event)
            }
            if userDefaults.bool(forKey: UserDefaultsKeys.shelfDropZoneEnabled) {
                handleDragForDock()
            }
        }
    }

    /// Detects a back-and-forth shake of the pointer during a drag: enough
    /// horizontal direction reversals and travel in a short window.
    private func handleDrag(_ event: NSEvent) {
        let t = event.timestamp
        shakeSamples.append(ShelfShakeSample(t: t, x: NSEvent.mouseLocation.x))
        shakeSamples.removeAll { t - $0.t > ShelfShakeDetector.window }

        guard ShelfShakeDetector.shouldSummon(samples: shakeSamples, now: t, lastSummon: lastSummon)
        else { return }

        // Only when content is actually being dragged — not when a window is
        // being moved (nothing droppable, so the shelf shouldn't appear).
        guard isContentDragActive() else { return }
        guard automaticOpenAllowed else { return }

        lastSummon = t
        shakeSamples.removeAll()
        summon()
    }

    private func isContentDragActive() -> Bool {
        let snapshot = dragPasteboardSnapshot()
        if snapshot.changeCount != dragPasteboardBaseline.changeCount { return true }
        return dragBeganInDock && snapshot.hasDroppableContent
    }

    private func dragPasteboardSnapshot() -> DragPasteboardSnapshot {
        let pasteboard = NSPasteboard(name: .drag)
        return DragPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            hasDroppableContent: pasteboardHasDroppableContent(pasteboard)
        )
    }

    private func pasteboardHasDroppableContent(_ pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        let directTypes: Set<String> = [
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            UTType.gif.identifier,
            UTType.fileURL.identifier,
            UTType.image.identifier,
            UTType.url.identifier,
            UTType.text.identifier,
            UTType.plainText.identifier,
            "NSFilenamesPboardType",
            "NSURLPboardType"
        ]
        let supportedUTTypes: [UTType] = [.fileURL, .gif, .image, .url, .text, .plainText]

        for item in items {
            for type in item.types {
                if directTypes.contains(type.rawValue) { return true }
                guard let utType = UTType(type.rawValue) else { continue }
                if supportedUTTypes.contains(where: { utType.conforms(to: $0) }) { return true }
            }
        }
        return false
    }

    private func eventBelongsToDock(_ event: NSEvent) -> Bool {
        if let cgEvent = event.cgEvent {
            let pid = pid_t(cgEvent.getIntegerValueField(.eventSourceUnixProcessID))
            if isDockProcess(pid) { return true }
        }

        guard event.windowNumber > 0 else { return false }
        guard let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow,
                                                     CGWindowID(event.windowNumber)) as? [[String: Any]],
              let info = infos.first else { return false }
        if let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
           isDockProcess(pid_t(pidNumber.int32Value)) {
            return true
        }
        return (info[kCGWindowOwnerName as String] as? String) == "Dock"
    }

    private func isDockProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }

    private var automaticOpenAllowed: Bool {
        ShelfInteractionSupport.allowsAutomaticOpen(
            sourceBundleIdentifier: dragSourceBundleIdentifier,
            excludedBundleIdentifiers: Set(automaticExclusions))
    }

    /// Global NSEvents sometimes expose the owning window directly and
    /// sometimes only the foreground app. Prefer the concrete event owner,
    /// then fall back to the foreground process so Finder and browsers remain
    /// classifiable without Screen Recording.
    private func sourceBundleIdentifier(for event: NSEvent) -> String? {
        if event.windowNumber > 0,
           let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow,
                                                  CGWindowID(event.windowNumber)) as? [[String: Any]],
           let pidNumber = infos.first?[kCGWindowOwnerPID as String] as? NSNumber,
           let bundleID = NSRunningApplication(processIdentifier: pid_t(pidNumber.int32Value))?.bundleIdentifier {
            return bundleID
        }
        if dragBeganInDock { return "com.apple.dock" }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Docked shelf (under the menu bar icon)

    /// Whether to show the full card rather than the pill. During a drag it is
    /// governed by pointer proximity; otherwise by the user's own collapse.
    var dockedExpanded: Bool {
        dockedDragActive ? dockedProximate : !dockedCollapsed
    }
    var dockedVisible: Bool { dockedPanel?.isVisible == true }

    private var dockedFeatureOn: Bool {
        featureAvailable()
            && userDefaults.bool(forKey: UserDefaultsKeys.shelfEnabled)
            && userDefaults.bool(forKey: UserDefaultsKeys.shelfDropZoneEnabled)
    }

    /// A qualifying drag is in flight: keep the pill under the icon as a small
    /// target, and let the card open only while the pointer is near it. With
    /// the classic floating panel already on screen, that panel is the target
    /// and the docked one stays out of the way.
    private func handleDragForDock() {
        guard dockedFeatureOn, automaticOpenAllowed, !isVisible,
              !isInternalDragActive, isContentDragActive() else { return }
        // Drag events still flowing means the drag is alive: a pending end
        // (queued by a mouse-up that turned out to start a new drag) is stale.
        dockedEndWork?.cancel()
        dockedEndWork = nil
        var changed = false
        if !dockedDragActive { dockedDragActive = true; changed = true }
        let near = mouseNearDock(NSEvent.mouseLocation)
        if near != dockedProximate { dockedProximate = near; changed = true }
        startDockedWatchdog()
        if changed { scheduleDockedSync() }
    }

    /// The drag ended. Drop the drag state; if a drop landed the shelf now has
    /// items and settles to a pill, otherwise it goes away. The short delay
    /// lets a drop that is still landing on the card claim it first.
    private func endDockedDrag() {
        guard dockedDragActive, dockedEndWork == nil else { return }
        dockedWatchdog?.invalidate()
        dockedWatchdog = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dockedEndWork = nil
            self.dockedDragActive = false
            self.dockedProximate = false
            // A drop keeps the tick pill; a miss just collapses.
            if !self.dockedJustCaught { self.dockedCollapsed = true }
            self.syncDockedShelf()
        }
        dockedEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Ends the drag state even when no mouse-up reaches the global monitor.
    private func startDockedWatchdog() {
        guard dockedWatchdog == nil else { return }
        dockedWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.dockedDragActive else {
                    self.dockedWatchdog?.invalidate()
                    self.dockedWatchdog = nil
                    return
                }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.endDockedDrag()
                }
            }
        }
        dockedWatchdog?.tolerance = 0.05
    }

    /// True when the pointer is close enough to the docked shelf to open it.
    private func mouseNearDock(_ mouse: NSPoint) -> Bool {
        guard let anchor = statusItemFrameProvider?() else { return false }
        if dockedProximate, let frame = dockedPanel?.frame {
            return frame.insetBy(dx: -72, dy: -72).contains(mouse)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? Self.screenWithMouse
        let band = NSRect(x: anchor.midX - 150,
                          y: screen.frame.maxY - 200,
                          width: 300, height: 200)
        return band.contains(mouse)
    }

    /// Called by the docked view when a drop lands: settle back to the pill
    /// with a brief green tick.
    func dockDidAccept() {
        dockedJustCaught = true
        dockedCollapsed = true
        dockedForcedOpen = false
        dockedFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dockedJustCaught = false
            self.scheduleDockedSync()
        }
        dockedFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
        scheduleDockedSync()
    }

    func expandDocked() {
        guard dockedFeatureOn else { summon(); return }
        // One shelf at a time: an explicit docked open takes over from a
        // classic panel left on screen.
        if isVisible { hide() }
        // Items keep the shelf up on their own; only forcing an empty one open
        // needs the flag.
        if itemCount == 0 { dockedForcedOpen = true }
        dockedCollapsed = false
        scheduleDockedSync()
    }

    func collapseDocked() {
        dockedCollapsed = true
        if itemCount == 0 { dockedForcedOpen = false }
        scheduleDockedSync()
    }

    func toggleDocked() {
        if dockedVisible, dockedExpanded {
            collapseDocked()
        } else {
            expandDocked()
        }
    }

    /// Shows the docked shelf when the option is on and there is a reason
    /// (items, drag, or explicit open). While the classic panel is on screen
    /// the docked one steps aside: one shelf at a time.
    func syncDockedShelf() {
        let wanted = dockedFeatureOn && !isVisible
            && (itemCount > 0 || dockedDragActive || dockedForcedOpen)
        guard wanted else { hideDocked(); return }
        let panel = ensureDockedPanel()
        if panel.contentViewController == nil {
            let host = NSHostingController(rootView: DockedShelfView().environmentObject(self))
            host.sizingOptions = .preferredContentSize
            panel.contentViewController = host
        }
        positionDocked(panel)
    }

    private func hideDocked() {
        dockedForcedOpen = false
        guard let dockedPanel, dockedPanel.isVisible else { return }
        dockedPanel.orderOut(nil)
    }

    /// Anchors the docked panel under the menu bar icon. Top edge stays put as
    /// it grows and shrinks. No frame animation (panel resize + SwiftUI swap lag).
    private func positionDocked(_ panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let anchor = statusItemFrameProvider?()
        let screen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? Self.screenWithMouse
        let visible = screen.visibleFrame
        var x = anchor.map { $0.midX - size.width / 2 } ?? (visible.maxX - size.width - 12)
        x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
        let top = visible.maxY - 4
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func ensureDockedPanel() -> NSPanel {
        if let dockedPanel {
            Self.activeForUI = self
            return dockedPanel
        }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        dockedPanel = panel
        Self.activeForUI = self
        appearance?.attach(panel)
        return panel
    }

    /// Keeps the docked shelf in step with items / drag state. Deferred so
    /// SwiftUI lays out before we measure.
    private func scheduleDockedSync() {
        DispatchQueue.main.async { [weak self] in self?.syncDockedShelf() }
    }

    func addAutomaticExclusion(_ bundleIdentifier: String) {
        let updated = Defaults.sanitizedBundleIdentifierList(automaticExclusions + [bundleIdentifier])
        guard updated != automaticExclusions else { return }
        automaticExclusions = updated
        userDefaults.set(updated, forKey: UserDefaultsKeys.shelfAutomaticExclusions)
    }

    func removeAutomaticExclusion(_ bundleIdentifier: String) {
        let updated = automaticExclusions.filter { $0 != bundleIdentifier }
        guard updated != automaticExclusions else { return }
        automaticExclusions = updated
        userDefaults.set(updated, forKey: UserDefaultsKeys.shelfAutomaticExclusions)
    }

    private func reloadAutomaticExclusions() {
        let stored = userDefaults.stringArray(forKey: UserDefaultsKeys.shelfAutomaticExclusions) ?? []
        let sanitized = Defaults.sanitizedBundleIdentifierList(stored)
        if stored != sanitized {
            userDefaults.set(sanitized, forKey: UserDefaultsKeys.shelfAutomaticExclusions)
        }
        if automaticExclusions != sanitized { automaticExclusions = sanitized }
    }

    // MARK: - Items

    /// Order matters for fidelity: a file is always a file, but a web image
    /// drag carries both an image and its page URL — prefer the image, and
    /// only fall back to treating a URL as a link when nothing richer exists.
    func accept(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.enumerated().filter {
            $0.element.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if fileProviders.count > 1, fileProviders.count == providers.count {
            acceptFileBatch(providers: fileProviders)
            return true
        }

        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in self?.addFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
                handled = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { [weak self] data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in self?.addGIF(data: data) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in self?.addImage(image) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        url.isFileURL ? self?.addFile(url) : self?.addLink(url)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { [weak self] string, _ in
                    guard let string = string as? String else { return }
                    Task { @MainActor in self?.addText(string) }
                }
            }
        }
        return handled
    }

    private func acceptFileBatch(providers: [(offset: Int, element: NSItemProvider)]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [(Int, URL)] = []

        for (index, provider) in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    loaded.append((index, url))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let urls = loaded.sorted { $0.0 < $1.0 }.map(\.1)
            Task { @MainActor in
                guard urls.count > 1 else {
                    if let url = urls.first { self.addFile(url) }
                    return
                }
                self.addFileBatch(urls)
            }
        }
    }

    func removeItem(_ id: UUID) {
        var removed: [Item] = []
        removeItems(Set([id]), from: &items, removed: &removed)
        cleanSelectionState()
        retireOwnedPayloads(in: removed)
        noteInteraction()
    }

    /// Removes several items at once — used after a successful drag-out so the
    /// tiles you dropped elsewhere leave the shelf.
    func removeItems(_ ids: [UUID]) {
        let set = Set(ids)
        var removed: [Item] = []
        removeItems(set, from: &items, removed: &removed)
        cleanSelectionState()
        retireOwnedPayloads(in: removed)
        noteInteraction()
    }

    func clear() {
        let removed = items
        items = []
        selection = []
        expandedBatches = []
        retireOwnedPayloads(in: removed)
        noteInteraction()
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        noteInteraction()
    }

    func toggleBatchExpansion(_ id: UUID) {
        guard let batch = item(withID: id), batch.isBatch else { return }
        if expandedBatches.contains(id) {
            expandedBatches.remove(id)
            selection.subtract(allIDs(in: batch.batchItems))
        } else {
            expandedBatches.insert(id)
        }
        noteInteraction()
    }

    func selectedItems() -> [Item] {
        selectedItems(in: items)
    }

    func dragItems(for item: Item) -> [Item] {
        dragItems(for: [item])
    }

    func dragItems(for items: [Item]) -> [Item] {
        var result: [Item] = []
        var seen = Set<UUID>()
        for item in items {
            appendDragLeaves(from: item, to: &result, seen: &seen)
        }
        return result
    }

    /// File actions use the current multi-selection when the clicked tile is
    /// part of it; otherwise they stay scoped to that tile. Batches flatten to
    /// their leaves just like an external drag.
    func fileURLsForActions(startingAt item: Item) -> [URL] {
        let candidates = selection.contains(item.id) ? selectedItems() : [item]
        return dragItems(for: candidates).compactMap { entry in
            guard case let .file(url) = entry.payload else { return nil }
            return url
        }
    }

    func beginInternalDrag(ids: [UUID]) {
        activeInternalDragIDs = ids
        internalDragWasMerged = false
    }

    func finishInternalDrag(dropAccepted: Bool) -> [UUID] {
        defer {
            activeInternalDragIDs = []
            internalDragWasMerged = false
        }
        guard dropAccepted, !internalDragWasMerged else { return [] }
        return activeInternalDragIDs
    }

    /// Completes a tile drag in one place so removal, dismissal, pinning and
    /// internal Shelf merges cannot drift apart across the AppKit views.
    func completeInternalDrag(dropAccepted: Bool) {
        let draggedIDs = finishInternalDrag(dropAccepted: dropAccepted)
        endInteraction()
        guard !draggedIDs.isEmpty else { return }

        if ShelfInteractionSupport.shouldRemoveAfterDrag(
            dropAccepted: dropAccepted,
            draggedItemCount: draggedIDs.count,
            removeAfterDrop: userDefaults.bool(forKey: UserDefaultsKeys.shelfRemoveAfterDrop)) {
            removeItems(draggedIDs)
        }
        if ShelfInteractionSupport.shouldCloseAfterDrag(
            dropAccepted: dropAccepted,
            draggedItemCount: draggedIDs.count,
            closeAfterDrop: userDefaults.bool(forKey: UserDefaultsKeys.shelfCloseAfterDrop),
            pinned: isPinned) {
            if isVisible {
                hide()
            } else if dockedExpanded {
                // Docked tiles only appear while expanded; collapse back to the pill.
                collapseDocked()
            }
        }
    }

    /// Retaining a file in the Shelf after use must offer copy-only outside
    /// the app; otherwise a destination may move it and leave a stale saved
    /// URL. Internal drops remain moves so stacking still works naturally.
    func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return .move }
        return userDefaults.bool(forKey: UserDefaultsKeys.shelfRemoveAfterDrop)
            ? [.copy, .move]
            : .copy
    }

    func canMergePasteboard(_ pasteboard: NSPasteboard, into targetID: UUID) -> Bool {
        if !activeInternalDragIDs.isEmpty {
            return canMergeInternalDrag(into: targetID)
        }
        return pasteboardCanCreateItem(pasteboard)
    }

    func mergePasteboard(_ pasteboard: NSPasteboard, into targetID: UUID) -> Bool {
        if !activeInternalDragIDs.isEmpty {
            return mergeInternalDrag(into: targetID)
        }
        let additions = items(from: pasteboard)
        guard !additions.isEmpty else { return false }
        return merge(additions, into: targetID)
    }

    func canAcceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        pasteboardCanCreateItem(pasteboard)
    }

    func accept(pasteboard: NSPasteboard) -> Bool {
        let fileURLs = fileURLs(from: pasteboard)
        if fileURLs.count > 1 {
            addFileBatch(fileURLs)
            return true
        }
        let additions = items(from: pasteboard)
        guard !additions.isEmpty else { return false }
        items.append(contentsOf: additions)
        noteInteraction()
        return true
    }

    /// The pasteboard representation used when dragging an item out of the shelf.
    func pasteboardWriter(for item: Item) -> NSPasteboardWriting {
        switch item.payload {
        case let .file(url): return url as NSURL
        case let .text(text): return text as NSString
        case let .link(url): return url as NSURL
        case let .batch(items):
            guard let first = dragItems(for: items).first else { return item.title as NSString }
            return pasteboardWriter(for: first)
        }
    }

    // MARK: - Panel

    func toggle() {
        isVisible ? hide() : summon()
    }

    func togglePin() {
        guard isVisible else { return }
        isPinned.toggle()
        if isPinned {
            cancelAutoHide()
        } else {
            scheduleAutoHideIfIdle()
        }
    }

    /// Opens the classic shelf near the cursor. Docked shelf steps aside while
    /// this panel is up and comes back when it closes.
    func summon() {
        let panel = ensurePanel()
        cancelAutoHide()
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        updatePointerInsidePanel()
        scheduleAutoHideIfIdle()
        scheduleDockedSync()
    }

    func hide() {
        resetAutoHide()
        isPinned = false
        panel?.orderOut(nil)
        scheduleDockedSync()
    }

    func noteInteraction() {
        guard panel?.isVisible == true else { return }
        cancelAutoHideFade()
        scheduleAutoHideIfIdle()
    }

    func setPointerInsidePanel(_ inside: Bool) {
        pointerInsidePanel = inside
        if inside {
            cancelAutoHide()
        } else {
            scheduleAutoHideIfIdle()
        }
    }

    func setDropTargeted(_ targeted: Bool) {
        guard dropTargeted != targeted else { return }
        dropTargeted = targeted
        if targeted {
            cancelAutoHide()
        } else {
            scheduleAutoHideIfIdle()
        }
    }

    func beginInteraction() {
        interactionDepth += 1
        cancelAutoHide()
    }

    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        scheduleAutoHideIfIdle()
    }

    private func resetAutoHide() {
        cancelAutoHide()
        pointerInsidePanel = false
        dropTargeted = false
        interactionDepth = 0
    }

    private func cancelAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        cancelAutoHideFade()
    }

    private func cancelAutoHideFade() {
        autoHideFadeTimer?.invalidate()
        autoHideFadeTimer = nil
        autoHideFadeStart = nil
        panel?.alphaValue = 1
    }

    private var shouldHoldOpen: Bool {
        isPinned || !items.isEmpty || pointerInsidePanel || dropTargeted || interactionDepth > 0
    }

    private func scheduleAutoHideIfIdle() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        guard panel?.isVisible == true, !shouldHoldOpen else { return }

        autoHideTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.autoHideIfIdle()
            }
        }
        autoHideTimer?.tolerance = 0.5
    }

    private func autoHideIfIdle() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        updatePointerInsidePanel()
        guard panel?.isVisible == true else { return }
        guard !shouldHoldOpen else {
            scheduleAutoHideIfIdle()
            return
        }
        fadeOutAndHide()
    }

    private func updatePointerInsidePanel() {
        guard let panel, panel.isVisible else {
            pointerInsidePanel = false
            return
        }
        pointerInsidePanel = panel.frame.contains(NSEvent.mouseLocation)
    }

    private func fadeOutAndHide() {
        guard let panel, panel.isVisible else { return }
        autoHideFadeTimer?.invalidate()
        autoHideFadeStart = Date()
        panel.alphaValue = 1

        autoHideFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else {
                    timer.invalidate()
                    return
                }
                self.updatePointerInsidePanel()
                guard !self.shouldHoldOpen else {
                    timer.invalidate()
                    self.autoHideFadeTimer = nil
                    self.autoHideFadeStart = nil
                    panel.alphaValue = 1
                    self.scheduleAutoHideIfIdle()
                    return
                }
                let elapsed = Date().timeIntervalSince(self.autoHideFadeStart ?? Date())
                let progress = min(1, elapsed / self.autoHideFadeDuration)
                panel.alphaValue = 1 - CGFloat(progress)
                guard progress >= 1 else { return }
                timer.invalidate()
                self.autoHideFadeTimer = nil
                self.autoHideFadeStart = nil
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.pointerInsidePanel = false
                self.dropTargeted = false
                self.interactionDepth = 0
                // The classic panel leaving is the docked shelf's cue to return.
                self.scheduleDockedSync()
            }
        }
        autoHideFadeTimer?.tolerance = 0.02
    }

    /// Re-fits the panel to its content (anchored at the top-left) after items
    /// change while it's on screen. Deferred so SwiftUI lays out first.
    private func scheduleRefit() {
        DispatchQueue.main.async { [weak self] in self?.refitIfVisible() }
    }

    private func refitIfVisible() {
        guard let panel, panel.isVisible else { return }
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true, animate: false)
    }

    private func position(_ panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = Self.screenWithMouse.visibleFrame
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 16
        x = min(max(screen.minX + 8, x), screen.maxX - size.width - 8)
        y = min(max(screen.minY + 8, y), screen.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Not movable by background: dragging a tile must start an item drag.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingController(rootView: ShelfView().environmentObject(self))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        self.panel = panel
        Self.activeForUI = self
        appearance?.attach(panel)
        return panel
    }

    /// Screen under the mouse pointer; falls back to main / first screen.
    private static var screenWithMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: - Testing hooks

    /// Waits until restore has completed (or times out). For unit tests.
    func waitForRestoreForTesting(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !restoreCompleted {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Allow the main-queue merge of restored items to settle.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        return true
    }

    /// Flushes a pending coalesced persist so tests can read UserDefaults.
    func flushPersistForTesting() async {
        // Wait for restore gate, then schedule and wait for the async write.
        _ = await waitForRestoreForTesting()
        schedulePersist()
        // Main async coalescer
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        // Persist queue
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            persistQueue.async { cont.resume() }
        }
    }

    // MARK: - Private item builders

    private func addFile(_ url: URL) {
        append(fileItem(for: url))
    }

    private func addFileBatch(_ urls: [URL]) {
        let children = urls.map { fileItem(for: $0) }
        append(batchItem(children: children))
    }

    private func addImage(_ image: NSImage) {
        guard let item = imageItem(for: image) else { return }
        append(item)
    }

    private func addGIF(data: Data) {
        guard let item = gifItem(for: data) else { return }
        append(item)
    }

    private func addText(_ string: String) {
        guard let item = textItem(for: string) else { return }
        append(item)
    }

    private func addLink(_ url: URL) {
        append(linkItem(for: url))
    }

    private func fileItem(for url: URL, id: UUID = UUID(), title: String? = nil) -> Item {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp"]
        let isImage = imageExtensions.contains(url.pathExtension.lowercased())
        let fallbackIcon = NSWorkspace.shared.icon(forFile: url.path)
        let icon = (isImage ? thumbnail(forFile: url) : nil) ?? fallbackIcon
        return Item(id: id, payload: .file(url), title: title ?? url.lastPathComponent,
                    icon: icon, isImage: isImage)
    }

    private func imageItem(for image: NSImage) -> Item? {
        let icon = image
        if let png = autoreleasepool(invoking: { () -> Data? in
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }), let url = storePayloadData(png, fileExtension: "png") {
            return Item(payload: .file(url), title: L10n().s.shelfItemImage, icon: icon, isImage: true)
        }
        return nil
    }

    private func gifItem(for data: Data) -> Item? {
        guard let url = storePayloadData(data, fileExtension: "gif") else { return nil }
        let icon = thumbnail(forFile: url) ?? symbol("photo")
        return Item(payload: .file(url), title: "GIF", icon: icon, isImage: true)
    }

    /// Writes a pasted payload where it can outlive this run; only if the
    /// Application Support store is unavailable does it fall back to the temp
    /// dir (the item then works for this session, as it always did).
    private func storePayloadData(_ data: Data, fileExtension: String) -> URL? {
        try? fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let url = storeDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Fallback to session temp.
            let fallback = tempDir.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            do {
                try data.write(to: fallback, options: .atomic)
                return fallback
            } catch {
                return nil
            }
        }
        return url
    }

    private func textItem(for string: String) -> Item? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let icon = symbol("doc.plaintext")
        return Item(payload: .text(string), title: String(firstLine.prefix(48)), icon: icon, isImage: false)
    }

    private func linkItem(for url: URL) -> Item {
        Item(payload: .link(url), title: url.host ?? url.absoluteString, icon: symbol("link"), isImage: false)
    }

    private func append(_ item: Item) {
        items.append(item)
        noteInteraction()
    }

    private func batchItem(id: UUID = UUID(), children: [Item]) -> Item {
        let total = children.reduce(0) { $0 + $1.leafCount }
        let title = children.first.map { "\($0.title) +\(max(0, total - 1))" } ?? ""
        let icon = children.first?.icon ?? symbol("doc.on.doc")
        return Item(id: id, payload: .batch(children), title: title, icon: icon, isImage: false)
    }

    private func items(from pasteboard: NSPasteboard) -> [Item] {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return fileURLs.map { fileItem(for: $0) }
        }
        if let gif = gifData(from: pasteboard),
           let item = gifItem(for: gif) {
            return [item]
        }
        if let image = NSImage(pasteboard: pasteboard),
           let item = imageItem(for: image) {
            return [item]
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
           let url = urls.map({ $0 as URL }).first(where: { !$0.isFileURL }) {
            return [linkItem(for: url)]
        }
        if let string = pasteboard.string(forType: .string),
           let item = textItem(for: string) {
            return [item]
        }
        return []
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [NSURL],
           !urls.isEmpty {
            return unique(urls.map { $0 as URL }.filter(\.isFileURL))
        }
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           !paths.isEmpty {
            return unique(paths.map { URL(fileURLWithPath: $0) })
        }
        return []
    }

    private func pasteboardCanCreateItem(_ pasteboard: NSPasteboard) -> Bool {
        if !fileURLs(from: pasteboard).isEmpty {
            return true
        }
        if pasteboardHasGIF(pasteboard) {
            return true
        }
        if pasteboardHasImage(pasteboard) {
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL],
           urls.contains(where: { !($0 as URL).isFileURL }) {
            return true
        }
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private func gifData(from pasteboard: NSPasteboard) -> Data? {
        for type in pasteboard.types ?? [] {
            guard pasteboardTypeIsGIF(type),
                  let data = pasteboard.data(forType: type),
                  !data.isEmpty else {
                continue
            }
            return data
        }
        return nil
    }

    private func pasteboardHasGIF(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains(where: pasteboardTypeIsGIF)
    }

    private func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        for type in pasteboard.types ?? [] {
            if pasteboardTypeIsGIF(type) { continue }
            if type == .png || type == .tiff { return true }
            if UTType(type.rawValue)?.conforms(to: .image) == true { return true }
        }
        return false
    }

    private func pasteboardTypeIsGIF(_ type: NSPasteboard.PasteboardType) -> Bool {
        type.rawValue == UTType.gif.identifier
            || UTType(type.rawValue)?.conforms(to: .gif) == true
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func canMergeInternalDrag(into targetID: UUID) -> Bool {
        guard !activeInternalDragIDs.isEmpty,
              !activeInternalDragIDs.contains(targetID),
              let target = item(withID: targetID)
        else { return false }
        let active = Set(activeInternalDragIDs)
        guard allIDs(in: target.batchItems).isDisjoint(with: active) else { return false }
        return !items(withIDs: active, in: items).isEmpty
    }

    private func mergeInternalDrag(into targetID: UUID) -> Bool {
        guard canMergeInternalDrag(into: targetID) else { return false }
        let sourceIDs = Set(activeInternalDragIDs)
        let additions = dragItems(for: items(withIDs: sourceIDs, in: items))
        guard !additions.isEmpty else { return false }

        var moved: [Item] = []
        removeItems(sourceIDs, from: &items, removed: &moved)
        guard merge(additions, into: targetID) else { return false }
        internalDragWasMerged = true
        return true
    }

    private func merge(_ additions: [Item], into targetID: UUID) -> Bool {
        let leaves = dragItems(for: additions)
        guard !leaves.isEmpty,
              leaves.allSatisfy({ $0.id != targetID }),
              merge(leaves, into: targetID, in: &items)
        else { return false }
        cleanSelectionState()
        noteInteraction()
        return true
    }

    private func merge(_ additions: [Item], into targetID: UUID, in items: inout [Item]) -> Bool {
        for index in items.indices {
            if items[index].id == targetID {
                switch items[index].payload {
                case let .batch(children):
                    items[index] = batchItem(id: items[index].id, children: children + additions)
                case .file, .text, .link:
                    items[index] = batchItem(id: items[index].id, children: [items[index]] + additions)
                }
                return true
            }

            guard case var .batch(children) = items[index].payload else { continue }
            if merge(additions, into: targetID, in: &children) {
                items[index] = batchItem(id: items[index].id, children: children)
                return true
            }
        }
        return false
    }

    private func retireOwnedPayloads(in removed: [Item]) {
        let urls = removed.flatMap { ownedPayloadURLs(in: $0) }
        guard !urls.isEmpty else { return }
        // Tests need deterministic cleanup; production still delays 10 minutes so
        // a drop that reuses the same path briefly is not raced.
        let delay: TimeInterval = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? 0
            : 10 * 60
        let owned = urls.filter { isShelfOwnedFile($0) }
        let fm = fileManager
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            for url in owned {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Payload files the shelf itself wrote (pasted images and GIFs) and may
    /// therefore delete; files the user dropped are never touched.
    private func ownedPayloadURLs(in item: Item) -> [URL] {
        switch item.payload {
        case let .file(url):
            return isShelfOwnedFile(url) ? [url] : []
        case .text, .link:
            return []
        case let .batch(items):
            return items.flatMap { ownedPayloadURLs(in: $0) }
        }
    }

    private func removeItems(_ ids: Set<UUID>, from items: inout [Item], removed: inout [Item]) {
        var kept: [Item] = []
        for item in items {
            if ids.contains(item.id) {
                removed.append(item)
                continue
            }

            guard case var .batch(children) = item.payload else {
                kept.append(item)
                continue
            }

            removeItems(ids, from: &children, removed: &removed)
            if children.isEmpty {
                expandedBatches.remove(item.id)
            } else if children.count == 1 {
                expandedBatches.remove(item.id)
                kept.append(children[0])
            } else {
                kept.append(batchItem(id: item.id, children: children))
            }
        }
        items = kept
    }

    private func visibleItems(in items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            result.append(item)
            if expandedBatches.contains(item.id), case let .batch(children) = item.payload {
                result.append(contentsOf: visibleItems(in: children))
            }
        }
        return result
    }

    private func selectedItems(in items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            if selection.contains(item.id) { result.append(item) }
            if case let .batch(children) = item.payload {
                result.append(contentsOf: selectedItems(in: children))
            }
        }
        return result
    }

    private func appendDragLeaves(from item: Item, to result: inout [Item], seen: inout Set<UUID>) {
        switch item.payload {
        case .file, .text, .link:
            guard seen.insert(item.id).inserted else { return }
            result.append(item)
        case let .batch(items):
            for child in items {
                appendDragLeaves(from: child, to: &result, seen: &seen)
            }
        }
    }

    private func item(withID id: UUID) -> Item? {
        item(withID: id, in: items)
    }

    private func item(withID id: UUID, in items: [Item]) -> Item? {
        for item in items {
            if item.id == id { return item }
            if case let .batch(children) = item.payload,
               let found = self.item(withID: id, in: children) {
                return found
            }
        }
        return nil
    }

    private func items(withIDs ids: Set<UUID>, in items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            if ids.contains(item.id) { result.append(item) }
            if case let .batch(children) = item.payload {
                result.append(contentsOf: self.items(withIDs: ids, in: children))
            }
        }
        return result
    }

    private func allIDs(in items: [Item]) -> Set<UUID> {
        var ids = Set<UUID>()
        for item in items {
            ids.insert(item.id)
            if case let .batch(children) = item.payload {
                ids.formUnion(allIDs(in: children))
            }
        }
        return ids
    }

    private func batchIDs(in items: [Item]) -> Set<UUID> {
        var ids = Set<UUID>()
        for item in items {
            if case let .batch(children) = item.payload {
                ids.insert(item.id)
                ids.formUnion(batchIDs(in: children))
            }
        }
        return ids
    }

    private func cleanSelectionState() {
        selection.formIntersection(allIDs(in: items))
        expandedBatches.formIntersection(batchIDs(in: items))
    }

    private func cleanTemporaryFiles(keeping keptPaths: Set<String>) {
        guard let entries = try? fileManager.contentsOfDirectory(at: tempDir,
                                                                 includingPropertiesForKeys: nil) else { return }
        for url in entries where isShelfOwnedFile(url) && !keptPaths.contains(url.standardizedFileURL.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func isShelfOwnedFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(tempDir.standardizedFileURL.path + "/") { return true }
        return path.hasPrefix(storeDirectory.standardizedFileURL.path + "/")
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private func thumbnail(forFile url: URL) -> NSImage? {
        // Lightweight: prefer workspace icon; image files can use NSImage(contentsOf:).
        if let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    // MARK: - Persistence

    /// Coalesces the saves of one mutation cycle into a single write. Gated
    /// until the restore lands so an early mutation cannot overwrite the saved
    /// shelf with a partial list.
    private func schedulePersist() {
        guard restoreCompleted, !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            self.persistItems()
        }
    }

    private func persistItems() {
        let persisted = items.map(Self.persistedItem(from:))
        let defaults = userDefaults
        persistQueue.async {
            guard let data = try? JSONEncoder().encode(persisted) else { return }
            defaults.set(data, forKey: UserDefaultsKeys.shelfItems)
        }
    }

    /// Restores the saved shelf off the main thread (file checks and image
    /// thumbnails touch the disk, and this runs at launch), merges it with
    /// anything added in the meantime, then sweeps payload files that lost
    /// their item (crash between write and save, or dropped at sanitizing).
    private func restoreItems() {
        let data = userDefaults.data(forKey: UserDefaultsKeys.shelfItems)
        let fm = fileManager
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var restored: [Item] = []
            if let data,
               let decoded = try? JSONDecoder().decode([ShelfPersistedItem].self, from: data) {
                let sanitized = ShelfPersistenceSupport.sanitized(decoded) { path in
                    if fm.fileExists(atPath: path) { return true }
                    // A file on an unmounted volume is not gone: the app can
                    // launch at login before an external or network drive
                    // appears, and dropping the item here would lose it the
                    // moment the pruned list is saved back.
                    if let volumeRoot = ShelfPersistenceSupport.unmountedVolumeRoot(of: path) {
                        return !fm.fileExists(atPath: volumeRoot)
                    }
                    return false
                }
                // restoredItem uses NSWorkspace / NSImage — MainActor-safe build
                // is done on main below; only decode/sanitize here.
                restored = sanitized.compactMap { Self.restoredItemStatic(from: $0) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restoreCompleted = true
                if restored.isEmpty {
                    self.schedulePersist()
                } else {
                    self.items = restored + self.items
                }
                let keptPaths = Set(self.items.flatMap { self.ownedPayloadURLs(in: $0) }
                    .map(\.standardizedFileURL.path))
                let sweepCutoff = Date()
                let store = self.storeDirectory
                let temp = self.tempDir
                let fileManager = self.fileManager
                DispatchQueue.global(qos: .utility).async {
                    Self.sweepOwnedFiles(storeDirectory: store,
                                         tempDir: temp,
                                         fileManager: fileManager,
                                         keeping: keptPaths,
                                         writtenBefore: sweepCutoff)
                }
            }
        }
    }

    private static func persistedItem(from item: Item) -> ShelfPersistedItem {
        switch item.payload {
        case let .file(url):
            return ShelfPersistedItem(id: item.id, kind: .file, title: item.title, path: url.path)
        case let .text(text):
            return ShelfPersistedItem(id: item.id, kind: .text, title: item.title, text: text)
        case let .link(url):
            return ShelfPersistedItem(id: item.id, kind: .link, title: item.title,
                                      url: url.absoluteString)
        case let .batch(children):
            return ShelfPersistedItem(id: item.id, kind: .batch, title: item.title,
                                      children: children.map(persistedItem(from:)))
        }
    }

    /// Builds an Item from persisted data without touching instance state.
    /// Icons are rebuilt from payload; missing image files still produce a
    /// file item with a workspace icon.
    private static func restoredItemStatic(from persisted: ShelfPersistedItem) -> Item? {
        switch persisted.kind {
        case .file:
            guard let path = persisted.path else { return nil }
            let url = URL(fileURLWithPath: path)
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp"]
            let isImage = imageExtensions.contains(url.pathExtension.lowercased())
            let fallbackIcon = NSWorkspace.shared.icon(forFile: url.path)
            let icon: NSImage
            if isImage, let image = NSImage(contentsOf: url) {
                icon = image
            } else {
                icon = fallbackIcon
            }
            let title = persisted.title.isEmpty ? url.lastPathComponent : persisted.title
            return Item(id: persisted.id, payload: .file(url), title: title, icon: icon, isImage: isImage)
        case .text:
            guard let text = persisted.text else { return nil }
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            let title = persisted.title.isEmpty ? String(firstLine.prefix(48)) : persisted.title
            let icon = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil) ?? NSImage()
            return Item(id: persisted.id, payload: .text(text), title: title, icon: icon, isImage: false)
        case .link:
            guard let raw = persisted.url, let url = URL(string: raw) else { return nil }
            let title = persisted.title.isEmpty ? (url.host ?? url.absoluteString) : persisted.title
            let icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
            return Item(id: persisted.id, payload: .link(url), title: title, icon: icon, isImage: false)
        case .batch:
            let children = (persisted.children ?? []).compactMap { restoredItemStatic(from: $0) }
            guard !children.isEmpty else { return nil }
            guard children.count > 1 else { return children[0] }
            let total = children.reduce(0) { $0 + $1.leafCount }
            let title = persisted.title.isEmpty
                ? (children.first.map { "\($0.title) +\(max(0, total - 1))" } ?? "")
                : persisted.title
            let icon = children.first?.icon
                ?? NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                ?? NSImage()
            return Item(id: persisted.id, payload: .batch(children), title: title, icon: icon, isImage: false)
        }
    }

    /// Deletes shelf-written payload files no restored item references.
    /// Only files written before the reference snapshot are touched: the sweep
    /// runs on a background queue, and a payload pasted between the snapshot
    /// and the enumeration must not be deleted out from under its fresh item.
    private static func sweepOwnedFiles(storeDirectory: URL,
                                        tempDir: URL,
                                        fileManager: FileManager,
                                        keeping keptPaths: Set<String>,
                                        writtenBefore cutoff: Date) {
        if let entries = try? fileManager.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for url in entries where !keptPaths.contains(url.standardizedFileURL.path) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
        if let entries = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for url in entries {
                let path = url.standardizedFileURL.path
                let isOwned = path.hasPrefix(tempDir.standardizedFileURL.path + "/")
                if isOwned && !keptPaths.contains(path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }
}
