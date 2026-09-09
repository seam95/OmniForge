import XCTest
@testable import OmniForge

@MainActor
final class StatusBarSettingsRoutingTests: XCTestCase {
    func test_statusBarController_forwardsOpenSettingsCallbackToPopoverRoot() {
        let state = makeRoutingState()
        let windowController = ClipboardWindowController(state: state)
        var openSettingsCount = 0
        var lastTab: SettingsToolbarTab?

        let controller = StatusBarController(
            state: state,
            clipboardWindowController: windowController,
            onOpenSettings: { tab in
                openSettingsCount += 1
                lastTab = tab
            }
        )

        controller.installPanelContentIfNeeded()
        controller.invokeOpenSettingsForTesting()

        XCTAssertEqual(openSettingsCount, 1)
        XCTAssertNil(lastTab)
    }

    func test_statusBarController_openKeepAwakeSettings_routesToKeepAwakeTab() {
        let state = makeRoutingState()
        let windowController = ClipboardWindowController(state: state)
        var lastTab: SettingsToolbarTab?

        let controller = StatusBarController(
            state: state,
            clipboardWindowController: windowController,
            onOpenSettings: { lastTab = $0 }
        )

        controller.invokeOpenKeepAwakeSettingsForTesting()
        XCTAssertEqual(lastTab, .keepAwake)
    }

    private func makeRoutingState() -> AppState {
        let defaults = UserDefaults(suiteName: "StatusBarSettingsRoutingTests")!
        defaults.removePersistentDomain(forName: "StatusBarSettingsRoutingTests")
        return AppState(
            inputMethods: InputMethodManager(
                tis: FakeTISClient(inputSources: [], currentID: "a"),
                scheduler: ImmediateScheduler(),
                notifications: FakeNotificationCenterClient()
            ),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            appearance: AppearanceSettings(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(
                client: FakeLaunchAtLoginClient(),
                userDefaults: defaults
            ),
            clipboardHistory: ClipboardHistoryManager(
                store: RoutingClipboardStore(),
                userDefaults: defaults
            ),
            clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
            quickPhrases: QuickPhraseManager(store: RoutingQuickPhraseStore()),
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

private final class RoutingClipboardStore: ClipboardStore {
    func loadEntries() -> [ClipboardEntry] { [] }
    func saveEntries(_ entries: [ClipboardEntry]) {}
    func releaseMemory() {}
}

private final class RoutingQuickPhraseStore: QuickPhraseStore {
    func loadPhrases() -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) {}
    func deletePhrase(id: UUID) {}
    func updatePhrase(_ phrase: QuickPhraseEntry) {}
    func releaseMemory() {}
}
