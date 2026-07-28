import AppKit
import Carbon
import SwiftUI

@MainActor
final class ClipboardWindowController: NSObject, NSWindowDelegate {
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let panel: NSPanel
    private var uiState: ClipboardOverlayState?
    private var quickPhraseState: QuickPhraseOverlayState?
    private var tabState: TabPanelState?
    private var previousActiveApp: NSRunningApplication?
    private var pasteTargetPID: pid_t?
    private var keyEventMonitor: Any?
    private var activeAppObserver: Any?
    private var lastNonSelfActiveApp: NSRunningApplication?
    private var isProgrammaticDismiss = false
    /// content 释放后 AppKit 可能把 panel 压成 1×1；用内存记忆最后一次有效 frame。
    private var rememberedFrame: NSRect?

    private let minimumWindowSize = NSSize(width: 400, height: 300)
    private let defaultWindowSize = NSSize(width: 720, height: 460)

    // 强持有 AppState：manager 可为 nil（未安装），但 state 生命周期由组合根保证
    private let appState: AppState
    private var clipboardHistory: ClipboardHistoryManager?
    private var quickPhrases: QuickPhraseManager?
    private let l10n: L10n
    private let pasteService = ClipboardPasteService()
    private let clearImageCache: () -> Void

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
        }
    }

    convenience init(state: AppState) {
        self.init(
            state: state,
            clearImageCache: { ClipboardImageCache.shared.clearAll() }
        )
    }

    init(state: AppState, clearImageCache: @escaping () -> Void) {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.borderless, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.appState = state
        self.clipboardHistory = state.clipboardHistory
        self.quickPhrases = state.quickPhrases
        self.l10n = state.l10n
        self.clearImageCache = clearImageCache
        super.init()

        panel.title = state.l10n.s.clipboardTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = minimumWindowSize
        panel.delegate = self

        restoreWindowFrame()

        startActiveAppObserver()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggleVisibility() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // 从 AppState 刷新可选 Manager（安装/卸载后可能变化）
        clipboardHistory = appState.clipboardHistory
        quickPhrases = appState.quickPhrases
        guard clipboardHistory != nil || quickPhrases != nil else { return }

        // releaseViewSession 可能把 panel 压成 1×1；show 前/后都恢复记忆 frame 并校正屏外位置。
        ensureValidVisibleFrame()
        if panel.isVisible {
            panel.orderFrontRegardless()
            panel.makeKey()
            requestSearchFocus()
            return
        }
        rememberPreviousApp()
        installViewIfNeeded()
        // 重新挂 content 后 AppKit 可能再次改写 frame，装载后再校正一次。
        ensureValidVisibleFrame()
        guard let tabState else { return }
        tabState.selectedTab = .clipboard
        resetCurrentTabState()
        updatePasteTargetName()
        requestSearchFocus()
        startKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        ensureValidVisibleFrame()
        // 临时激活应用以支持中文输入法
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resetCurrentTabState() {
        guard let tabState, let uiState, let quickPhraseState else { return }
        switch tabState.selectedTab {
        case .clipboard:
            uiState.resetForNewSession()
        case .quickPhrase:
            quickPhraseState.resetForNewSession()
        }
    }

    private func requestSearchFocus() {
        guard let tabState, let uiState, let quickPhraseState else { return }
        switch tabState.selectedTab {
        case .clipboard:
            uiState.requestSearchFocus()
        case .quickPhrase:
            quickPhraseState.requestSearchFocus()
        }
    }

    private func updatePasteTargetName() {
        guard let uiState, let quickPhraseState else { return }
        let appName = previousActiveApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName
        uiState.pasteTargetAppName = appName
        quickPhraseState.updatePasteTargetName(appName)
    }

    func hide() {
        dismiss(shouldRestorePreviousApp: true)
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        dismiss(shouldRestorePreviousApp: true)
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        guard !isProgrammaticDismiss else { return }
        // 有 sheet（如快捷短语编辑器）显示时，不关闭面板
        if panel.attachedSheet != nil { return }
        // 用户点击窗口外导致窗口失去焦点时，不要再强行激活”之前的应用”，避免抢走用户刚点击的焦点。
        dismiss(shouldRestorePreviousApp: false)
    }

    func handleEscapeKey() {
        guard panel.isVisible else { return }
        guard let tabState, let uiState, let quickPhraseState else { return }

        let hasSearchText: Bool
        switch tabState.selectedTab {
        case .clipboard:
            hasSearchText = !uiState.searchText.isEmpty
            if hasSearchText {
                uiState.searchText = ""
                uiState.requestSearchFocus()
                return
            }
        case .quickPhrase:
            hasSearchText = !quickPhraseState.searchText.isEmpty
            if hasSearchText {
                quickPhraseState.searchText = ""
                quickPhraseState.requestSearchFocus()
                return
            }
        }

        hide()
    }

    private func installView() {
        guard let clipboardHistory, let quickPhrases else { return }

        let uiState = ClipboardOverlayState()
        let quickPhraseState = QuickPhraseOverlayState()
        let tabState = TabPanelState()
        self.uiState = uiState
        self.quickPhraseState = quickPhraseState
        self.tabState = tabState

        panel.contentViewController = NSHostingController(
            rootView: AnyView(TabPanelView(
                tabState: tabState,
                clipboardView: ClipboardHistoryView(
                    history: clipboardHistory,
                    l10n: l10n,
                    uiState: uiState,
                    onRequestClose: { [weak self] in
                        self?.hide()
                    },
                    isReadyToPaste: { [weak self] in
                        self?.isReadyToPaste() ?? true
                    },
                    pasteTargetPIDProvider: { [weak self] in
                        self?.pasteTargetPID
                    }
                ),
                quickPhraseView: QuickPhraseView(
                    manager: quickPhrases,
                    uiState: quickPhraseState,
                    tabState: tabState,
                    l10n: l10n,
                    onRequestClose: { [weak self] in
                        self?.hide()
                    },
                    isReadyToPaste: { [weak self] in
                        self?.isReadyToPaste() ?? true
                    },
                    pasteTargetPIDProvider: { [weak self] in
                        self?.pasteTargetPID
                    }
                )
            ))
        )
    }

    private func installViewIfNeeded() {
        guard panel.contentViewController == nil else { return }
        installView()
    }

    private func rememberPreviousApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if isSelfApp(frontmost) {
            previousActiveApp = lastNonSelfActiveApp
        } else {
            previousActiveApp = frontmost
        }
        pasteTargetPID = previousActiveApp?.processIdentifier
    }

    private func dismiss(shouldRestorePreviousApp: Bool) {
        guard panel.isVisible else {
            if !shouldRestorePreviousApp {
                previousActiveApp = nil
            }
            return
        }

        saveWindowFrame()
        isProgrammaticDismiss = true
        stopKeyMonitor()
        panel.makeFirstResponder(nil)
        panel.contentView?.discardCursorRects()
        releaseViewSession()
        panel.orderOut(nil)
        NSCursor.arrow.set()

        let app = previousActiveApp
        previousActiveApp = nil
        isProgrammaticDismiss = false

        guard shouldRestorePreviousApp, let app else { return }
        // non-activating panel 模式下，原应用可能仍是 frontmost，但再次 activate 能确保其拿回键盘焦点，
        // 避免后续 CGEvent 的 Cmd+V 落到本应用的 key window（搜索框）里。
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func releaseViewSession() {
        clearImageCache()
        clipboardHistory?.releaseMemory()
        quickPhrases?.releaseMemory()
        if let hostingController = panel.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = AnyView(EmptyView())
        }
        panel.contentViewController = nil
        panel.contentView = nil
        uiState = nil
        quickPhraseState = nil
        tabState = nil
    }

    private func isPasteTargetActive() -> Bool {
        guard let pasteTargetPID else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pasteTargetPID
    }

    private func isReadyToPaste() -> Bool {
        // 非激活面板模式下 NSApp.isActive 可能始终为 false，
        // 需要额外确保面板已隐藏，否则 Cmd+V 可能仍会落到搜索框里。
        guard panel.isVisible == false else { return false }
        return isPasteTargetActive()
    }

    private func startActiveAppObserver() {
        guard activeAppObserver == nil else { return }
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard !self.isSelfApp(app) else { return }
            self.lastNonSelfActiveApp = app
        }
    }

    private func isSelfApp(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        guard let selfBundleID = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == selfBundleID
    }

    private func saveWindowFrame() {
        let frame = panel.frame
        guard isValidWindowSize(frame.size) else { return }
        rememberFrame(frame)
        persistFrame(frame)
    }

    private func restoreWindowFrame() {
        let candidate = loadPersistedFrame() ?? centeredFrame(size: defaultWindowSize)
        applyNormalizedFrame(candidate, persistIfChanged: true)
    }

    /// show 前校正：尺寸被压扁时回退到记忆/持久化 frame；屏外时居中。
    private func ensureValidVisibleFrame() {
        let candidate: NSRect
        if isValidWindowSize(panel.frame.size) {
            candidate = panel.frame
        } else if let rememberedFrame, isValidWindowSize(rememberedFrame.size) {
            candidate = rememberedFrame
        } else if let persisted = loadPersistedFrame() {
            candidate = persisted
        } else {
            candidate = centeredFrame(size: defaultWindowSize)
        }
        applyNormalizedFrame(candidate, persistIfChanged: true)
    }

    private func applyNormalizedFrame(_ candidate: NSRect, persistIfChanged: Bool) {
        let size = NSSize(
            width: max(candidate.width, minimumWindowSize.width),
            height: max(candidate.height, minimumWindowSize.height)
        )
        let sized = NSRect(origin: candidate.origin, size: size)
        let normalized = WindowFrameVisibility.normalizedFrameOnCurrentScreens(sized) {
            self.centeredFrame(size: size)
        }
        // 始终写入：content 重建后 origin 可能相同但 size 已被压扁。
        panel.setFrame(normalized, display: panel.isVisible)
        rememberFrame(normalized)
        if persistIfChanged {
            persistFrame(normalized)
        }
    }

    private func rememberFrame(_ frame: NSRect) {
        guard isValidWindowSize(frame.size) else { return }
        rememberedFrame = frame
    }

    private func persistFrame(_ frame: NSRect) {
        guard isValidWindowSize(frame.size) else { return }
        let frameDict: [String: CGFloat] = [
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height
        ]
        UserDefaults.standard.set(frameDict, forKey: UserDefaultsKeys.clipboardWindowFrame)
    }

    private func loadPersistedFrame() -> NSRect? {
        guard let frameDict = UserDefaults.standard.object(forKey: UserDefaultsKeys.clipboardWindowFrame) as? [String: CGFloat],
              let x = frameDict["x"],
              let y = frameDict["y"],
              let width = frameDict["width"],
              let height = frameDict["height"] else {
            return nil
        }
        return NSRect(
            x: x,
            y: y,
            width: max(width, minimumWindowSize.width),
            height: max(height, minimumWindowSize.height)
        )
    }

    private func isValidWindowSize(_ size: NSSize) -> Bool {
        size.width >= minimumWindowSize.width && size.height >= minimumWindowSize.height
    }

    /// 不依赖 `NSWindow.center()`：无 content 时它可能把尺寸压成 1×1。
    private func centeredFrame(size: NSSize) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func startKeyMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let tabState = self.tabState else { return event }

            // Tab 切换
            if event.keyCode == UInt16(kVK_Tab) {
                if event.modifierFlags.contains(.shift) {
                    tabState.selectPreviousTab()
                } else {
                    tabState.selectNextTab()
                }
                self.resetCurrentTabState()
                self.requestSearchFocus()
                return nil
            }

            // Escape 键
            if event.keyCode == UInt16(kVK_Escape) {
                self.handleEscapeKey()
                return nil
            }

            // 剪贴板面板：上/下导航 + 回车粘贴（与双击共用 paste 路径，不放在 SwiftUI View 的 @State monitor 里）
            if tabState.selectedTab == .clipboard {
                if event.keyCode == UInt16(kVK_DownArrow) {
                    self.navigateClipboard(direction: 1)
                    return nil
                }
                if event.keyCode == UInt16(kVK_UpArrow) {
                    self.navigateClipboard(direction: -1)
                    return nil
                }
                if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                    self.pasteSelectedClipboardEntry()
                    return nil
                }
            }

            // 快捷短语面板：上/下导航 + 左/右切换分组 + 回车粘贴
            if tabState.selectedTab == .quickPhrase {
                if event.keyCode == UInt16(kVK_DownArrow) {
                    self.navigateQuickPhrase(down: true)
                    return nil
                }
                if event.keyCode == UInt16(kVK_UpArrow) {
                    self.navigateQuickPhrase(down: false)
                    return nil
                }
                if event.keyCode == UInt16(kVK_LeftArrow) {
                    self.navigateQuickPhraseGroup(forward: false)
                    return nil
                }
                if event.keyCode == UInt16(kVK_RightArrow) {
                    self.navigateQuickPhraseGroup(forward: true)
                    return nil
                }
                if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                    self.pasteSelectedQuickPhrase()
                    return nil
                }
            }

            return event
        }
    }

    private func navigateClipboard(direction: Int) {
        guard let uiState, let clipboardHistory else { return }
        let entries = uiState.filteredEntries(from: clipboardHistory.entries)
        uiState.moveSelection(in: entries, direction: direction)
    }

    private func pasteSelectedClipboardEntry() {
        guard let uiState, let clipboardHistory else { return }
        let entries = uiState.filteredEntries(from: clipboardHistory.entries)
        guard let selectedID = uiState.selectedEntryID,
              var entry = entries.first(where: { $0.id == selectedID }) else {
            return
        }

        // blob 类型可能未加载完整内容，与双击路径一致先补全
        switch entry.content {
        case .text(nil), .image(nil), .rtf(nil), .unknown(nil):
            if let fullContent = clipboardHistory.fullContent(for: entry.id) {
                entry = entry.withContent(fullContent)
            }
        default:
            break
        }

        pasteService.paste(
            entry: entry,
            close: { [weak self] in self?.hide() },
            isReadyToPaste: { [weak self] in self?.isReadyToPaste() ?? true },
            targetPID: pasteTargetPID
        )
    }

    private func stopKeyMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        keyEventMonitor = nil
    }

    private func navigateQuickPhrase(down: Bool) {
        guard let quickPhraseState else { return }
        guard let quickPhrases else { return }
        let phrases = quickPhrases.filtered(searchText: quickPhraseState.searchText, group: quickPhraseState.selectedGroup)
        guard !phrases.isEmpty else { return }

        if let selectedID = quickPhraseState.selectedPhraseID,
           let currentIndex = phrases.firstIndex(where: { $0.id == selectedID }) {
            if down && currentIndex < phrases.count - 1 {
                quickPhraseState.selectedPhraseID = phrases[currentIndex + 1].id
            } else if !down && currentIndex > 0 {
                quickPhraseState.selectedPhraseID = phrases[currentIndex - 1].id
            }
        } else {
            quickPhraseState.selectedPhraseID = (down ? phrases.first : phrases.last)?.id
        }
    }

    private func navigateQuickPhraseGroup(forward: Bool) {
        guard let quickPhraseState else { return }
        guard let quickPhrases else { return }
        let groups: [String?] = [nil] + quickPhrases.allGroups()
        let currentIndex = groups.firstIndex(where: { $0 == quickPhraseState.selectedGroup }) ?? 0
        if forward && currentIndex < groups.count - 1 {
            quickPhraseState.selectedGroup = groups[currentIndex + 1]
        } else if !forward && currentIndex > 0 {
            quickPhraseState.selectedGroup = groups[currentIndex - 1]
        }
    }

    private func pasteSelectedQuickPhrase() {
        guard let quickPhraseState else { return }
        guard let selectedID = quickPhraseState.selectedPhraseID else { return }
        guard let quickPhrases else { return }
        let phrases = quickPhrases.filtered(searchText: quickPhraseState.searchText, group: quickPhraseState.selectedGroup)
        guard let phrase = phrases.first(where: { $0.id == selectedID }) else { return }

        let entry = ClipboardEntry(
            id: UUID(),
            createdAt: Date(),
            type: .text,
            preview: String(phrase.content.prefix(80)),
            sourceAppBundleID: nil,
            sourceAppName: nil,
            content: .text(phrase.content),
            thumbnailData: nil,
            blobSize: nil,
            imageWidth: nil,
            imageHeight: nil,
            contentHash: nil
        )
        pasteService.paste(
            entry: entry,
            close: { [weak self] in self?.hide() },
            isReadyToPaste: { [weak self] in self?.isReadyToPaste() ?? true },
            targetPID: pasteTargetPID
        )
    }
}
