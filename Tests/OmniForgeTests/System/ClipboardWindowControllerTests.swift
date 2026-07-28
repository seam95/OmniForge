import XCTest
import Combine
@testable import OmniForge

@MainActor
final class ClipboardWindowControllerTests: XCTestCase {
    func test_toggleShowsAndHidesWindow() {
        let controller = ClipboardWindowController(state: makeState())

        XCTAssertFalse(controller.isVisible)

        controller.toggleVisibility()

        XCTAssertTrue(controller.isVisible)

        controller.toggleVisibility()

        XCTAssertFalse(controller.isVisible)
    }

    func test_escapeKeyClosesWindow() {
        let state = makeState()
        let controller = ClipboardWindowController(state: state)

        controller.show()
        defer { controller.hide() }

        XCTAssertTrue(controller.isVisible)

        controller.handleEscapeKey()

        XCTAssertFalse(controller.isVisible)
    }

    func test_windowResigningKeyClosesWindow() {
        let state = makeState()
        let controller = ClipboardWindowController(state: state)

        controller.show()
        defer { controller.hide() }

        let title = state.l10n.s.clipboardTitle
        guard let window = NSApp.windows.first(where: { $0.title == title }) else {
            XCTFail("Window not found")
            return
        }

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))

        XCTAssertFalse(controller.isVisible)
    }

    func test_windowIsBorderlessAndHidesTrafficLights() {
        let state = makeState()
        let controller = ClipboardWindowController(state: state)

        controller.show()
        defer { controller.hide() }

        let title = state.l10n.s.clipboardTitle
        guard let window = NSApp.windows.first(where: { $0.title == title }) else {
            XCTFail("Window not found")
            return
        }

        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertEqual(window.standardWindowButton(.closeButton), nil)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton), nil)
        XCTAssertEqual(window.standardWindowButton(.zoomButton), nil)
    }

    func test_showKeepsLastWindowPosition() {
        let state = makeState()
        let controller = ClipboardWindowController(state: state)

        controller.show()
        defer { controller.hide() }

        let title = state.l10n.s.clipboardTitle
        guard let window = NSApp.windows.first(where: { $0.title == title }) else {
            XCTFail("Window not found")
            return
        }

        let movedOrigin = NSPoint(x: window.frame.origin.x + 80, y: window.frame.origin.y + 80)
        window.setFrameOrigin(movedOrigin)

        controller.hide()
        controller.show()

        XCTAssertEqual(window.frame.origin.x, movedOrigin.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, movedOrigin.y, accuracy: 0.5)
    }

    func test_hideReleasesContentViewControllerAndShowCreatesNewSession() {
        let clipboardStore = FakeClipboardStore(entries: [])
        let quickPhraseStore = FakeQuickPhraseStore()
        let state = makeState(
            clipboardStore: clipboardStore,
            quickPhraseStore: quickPhraseStore
        )
        var clearCount = 0
        let controller = ClipboardWindowController(
            state: state,
            clearImageCache: { clearCount += 1 }
        )
        let panel = tryUnwrapPanel(from: controller)

        XCTAssertNil(panel.contentViewController)

        weak var initialContentViewController: NSViewController?
        autoreleasepool {
            controller.show()
            initialContentViewController = panel.contentViewController
            XCTAssertNotNil(initialContentViewController)
            XCTAssertTrue(hasUIState(controller))

            controller.hide()

            XCTAssertNil(panel.contentViewController)
            XCTAssertFalse(hasUIState(controller))
        }

        XCTAssertNil(initialContentViewController)
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(clipboardStore.releaseMemoryCallCount, 1)
        XCTAssertEqual(quickPhraseStore.releaseMemoryCallCount, 1)

        controller.show()
        defer { controller.hide() }

        XCTAssertNotNil(panel.contentViewController)
        XCTAssertFalse(panel.contentViewController === initialContentViewController)
    }

    func test_windowIsNonActivatingPanelAndFloatsAboveStatusBar() {
        let state = makeState()
        let controller = ClipboardWindowController(state: state)

        controller.show()
        defer { controller.hide() }

        let title = state.l10n.s.clipboardTitle
        guard let window = NSApp.windows.first(where: { $0.title == title }) else {
            XCTFail("Window not found")
            return
        }

        XCTAssertTrue(window is NSPanel)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(window.level, .statusBar)
        XCTAssertTrue((window as? NSPanel)?.isFloatingPanel == true)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}

@MainActor
private func tryUnwrapPanel(from controller: ClipboardWindowController, file: StaticString = #filePath, line: UInt = #line) -> NSPanel {
    let mirror = Mirror(reflecting: controller)
    guard let panel = mirror.children.first(where: { $0.label == "panel" })?.value as? NSPanel else {
        XCTFail("Panel not found", file: file, line: line)
        return NSPanel()
    }
    return panel
}

@MainActor
private func hasUIState(_ controller: ClipboardWindowController) -> Bool {
    let mirror = Mirror(reflecting: controller)
    guard let value = mirror.children.first(where: { $0.label == "uiState" })?.value else {
        return false
    }
    return !Mirror(reflecting: value).children.isEmpty
}

@MainActor
private func makeState(
    clipboardStore: FakeClipboardStore = FakeClipboardStore(entries: []),
    quickPhraseStore: FakeQuickPhraseStore = FakeQuickPhraseStore()
) -> AppState {
    let tis = FakeTISClient(
        inputSources: [
            .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil)
        ],
        currentID: "a"
    )
    let notifications = FakeNotificationCenterClient()
    let scheduler = ImmediateScheduler()
    let defaults = UserDefaults(suiteName: "ClipboardWindowControllerTests")!
    defaults.removePersistentDomain(forName: "ClipboardWindowControllerTests")
    let hotkeyManager = ClipboardHotkeyManager(userDefaults: defaults)

    return AppState(
        inputMethods: InputMethodManager(tis: tis, scheduler: scheduler, notifications: notifications),
        lockState: LockStateManager(userDefaults: defaults),
        l10n: L10n(userDefaults: defaults),
        launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
        clipboardHistory: ClipboardHistoryManager(store: clipboardStore, userDefaults: defaults),
        clipboardHotkey: hotkeyManager,
        quickPhrases: QuickPhraseManager(store: quickPhraseStore),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
        userDefaults: defaults
    )
}

private final class FakeClipboardStore: ClipboardStore {
    private var entries: [ClipboardEntry]
    private(set) var releaseMemoryCallCount = 0

    init(entries: [ClipboardEntry]) {
        self.entries = entries
    }

    func loadEntries() -> [ClipboardEntry] {
        entries
    }

    func saveEntries(_ entries: [ClipboardEntry]) {
        self.entries = entries
    }

    func releaseMemory() {
        releaseMemoryCallCount += 1
    }
}

private final class FakeQuickPhraseStore: QuickPhraseStore {
    private(set) var releaseMemoryCallCount = 0

    func loadPhrases() -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) {}
    func deletePhrase(id: UUID) {}
    func updatePhrase(_ phrase: QuickPhraseEntry) {}
    func releaseMemory() {
        releaseMemoryCallCount += 1
    }
}

