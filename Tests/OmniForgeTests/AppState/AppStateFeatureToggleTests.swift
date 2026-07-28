import XCTest
import Combine
@testable import OmniForge

@MainActor
final class AppStateFeatureToggleTests: XCTestCase {
    func test_clipboardFeatureDisabledOnInit_stopsMonitoring() {
        let suite = "AppStateFeatureToggleTests_initOff"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: UserDefaultsKeys.clipboardFeatureEnabled)

        var startCount = 0
        var stopCount = 0

        _ = makeState(
            defaults: defaults,
            startClipboardMonitoring: { startCount += 1 },
            stopClipboardMonitoring: { stopCount += 1 }
        )

        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 1)
    }

    func test_setClipboardFeatureEnabled_togglesStateAndPersists() {
        let suite = "AppStateFeatureToggleTests_clipboardToggle"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let state = makeState(defaults: defaults)

        XCTAssertTrue(state.isClipboardFeatureEnabled)

        state.setClipboardFeatureEnabled(false)
        XCTAssertFalse(state.isClipboardFeatureEnabled)
        XCTAssertEqual(defaults.bool(forKey: UserDefaultsKeys.clipboardFeatureEnabled), false)

        state.setClipboardFeatureEnabled(true)
        XCTAssertTrue(state.isClipboardFeatureEnabled)
        XCTAssertEqual(defaults.bool(forKey: UserDefaultsKeys.clipboardFeatureEnabled), true)
    }

    func test_unlockKeepsSelectedInputSourceID() {
        let suite = "AppStateFeatureToggleTests_unlockKeepsSelected"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let state = makeState(defaults: defaults)

        state.selectInputSource(id: "b")
        state.setLocked(true)
        state.setLocked(false)

        XCTAssertEqual(state.selectedInputSourceID, "b")
        XCTAssertEqual(state.lockState?.lockedInputSourceID, "b")
    }

    func test_inputLockStopsObservationAndRestoresCorrectionWhenReenabled() {
        let suite = "AppStateFeatureToggleTests_inputRuntime"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let notifications = FakeNotificationCenterClient()
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil),
            ],
            currentID: "a"
        )
        let inputMethods = InputMethodManager(
            tis: tis,
            scheduler: ImmediateScheduler(),
            notifications: notifications
        )
        let state = makeState(
            defaults: defaults,
            inputMethods: inputMethods
        )

        XCTAssertFalse(inputMethods.isObservingInputSourceChanges)

        state.selectInputSource(id: "b")
        state.setLocked(true)
        XCTAssertTrue(inputMethods.isObservingInputSourceChanges)

        state.setLocked(false)
        XCTAssertFalse(inputMethods.isObservingInputSourceChanges)
        XCTAssertEqual(state.lockState?.lockedInputSourceID, "b")

        XCTAssertTrue(tis.selectInputSource(id: "a"))
        notifications.post(name: .tisSelectedKeyboardInputSourceChanged)
        XCTAssertEqual(tis.currentInputSourceID(), "a")

        state.setLocked(true)
        XCTAssertTrue(inputMethods.isObservingInputSourceChanges)
        XCTAssertEqual(tis.currentInputSourceID(), "b")
    }
}

@MainActor
private func makeState(
    defaults: UserDefaults,
    inputMethods: InputMethodManager? = nil,
    startClipboardMonitoring: (() -> Void)? = nil,
    stopClipboardMonitoring: (() -> Void)? = nil
) -> AppState {
    let tis = FakeTISClient(
        inputSources: [
            .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
            .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
        ],
        currentID: "a"
    )

    return AppState(
        inputMethods: inputMethods ?? InputMethodManager(
            tis: tis,
            scheduler: ImmediateScheduler(),
            notifications: FakeNotificationCenterClient()
        ),
        lockState: LockStateManager(userDefaults: defaults),
        l10n: L10n(userDefaults: defaults),
        launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
        clipboardHistory: ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults),
        clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
        quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
        userDefaults: defaults,
        startClipboardMonitoring: startClipboardMonitoring,
        stopClipboardMonitoring: stopClipboardMonitoring
    )
}

private final class FakeClipboardStore: ClipboardStore {
    private var entries: [ClipboardEntry]

    init(entries: [ClipboardEntry]) {
        self.entries = entries
    }

    func loadEntries() -> [ClipboardEntry] {
        entries
    }

    func saveEntries(_ entries: [ClipboardEntry]) {
        self.entries = entries
    }

    func releaseMemory() {}
}

private final class FakeQuickPhraseStore: QuickPhraseStore {
    func loadPhrases() -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) {}
    func deletePhrase(id: UUID) {}
    func updatePhrase(_ phrase: QuickPhraseEntry) {}
    func releaseMemory() {}
}
