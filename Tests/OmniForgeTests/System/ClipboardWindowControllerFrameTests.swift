import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class ClipboardWindowControllerFrameTests: XCTestCase {
    private let suiteName = "ClipboardWindowControllerFrameTests"

    override func setUp() {
        super.setUp()
        clearSavedFrame()
    }

    override func tearDown() {
        clearSavedFrame()
        super.tearDown()
    }

    func test_restoreWindowFrame_centersWhenSavedFrameIsOffscreen() {
        UserDefaults.standard.set(
            [
                "x": CGFloat(0),
                "y": CGFloat(-2754),
                "width": CGFloat(720),
                "height": CGFloat(460)
            ],
            forKey: UserDefaultsKeys.clipboardWindowFrame
        )

        let controller = ClipboardWindowController(state: makeFrameTestState(suiteName: suiteName))
        let panel = tryUnwrapPanel(from: controller)

        // init 已 restore；show 也会再次 ensure
        controller.show()
        defer { controller.hide() }

        let frame = panel.frame
        XCTAssertGreaterThanOrEqual(frame.width, 400)
        XCTAssertGreaterThanOrEqual(frame.height, 300)
        let isOnAnyScreen = NSScreen.screens.contains { screen in
            let intersection = frame.intersection(screen.visibleFrame)
            return !intersection.isNull
                && intersection.width >= 50
                && intersection.height >= 50
        }
        XCTAssertTrue(
            isOnAnyScreen,
            "Expected clipboard panel to be recentered onto a visible screen, got \(frame)"
        )
    }

    private func clearSavedFrame() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.clipboardWindowFrame)
    }

    private func tryUnwrapPanel(
        from controller: ClipboardWindowController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NSPanel {
        let mirror = Mirror(reflecting: controller)
        guard let panel = mirror.children.first(where: { $0.label == "panel" })?.value as? NSPanel else {
            XCTFail("Panel not found", file: file, line: line)
            return NSPanel()
        }
        return panel
    }

    private func makeFrameTestState(suiteName: String) -> AppState {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(
            inputMethods: InputMethodManager(
                tis: FakeTISClient(
                    inputSources: [
                        .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil)
                    ],
                    currentID: "a"
                ),
                scheduler: ImmediateScheduler(),
                notifications: FakeNotificationCenterClient()
            ),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(
                client: FakeLaunchAtLoginClient(),
                userDefaults: defaults
            ),
            clipboardHistory: ClipboardHistoryManager(
                store: FrameTestClipboardStore(),
                userDefaults: defaults
            ),
            clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
            quickPhrases: QuickPhraseManager(store: FrameTestQuickPhraseStore()),
            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(
                notificationClient: FakeAlertNotifier(),
                configuration: .init()
            ),
            userDefaults: defaults
        )
    }
}

private final class FrameTestClipboardStore: ClipboardStore {
    func loadEntries() -> [ClipboardEntry] { [] }
    func saveEntries(_ entries: [ClipboardEntry]) {}
    func releaseMemory() {}
}

private final class FrameTestQuickPhraseStore: QuickPhraseStore {
    func loadPhrases() -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) {}
    func deletePhrase(id: UUID) {}
    func updatePhrase(_ phrase: QuickPhraseEntry) {}
    func releaseMemory() {}
}
