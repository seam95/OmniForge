import Combine
import XCTest
@testable import OmniForge

@MainActor
final class AppStateFeatureRuntimeTests: XCTestCase {
    func test_appStateWorksAfterFeatureRuntimeRegistration() {
        FeatureRuntime.shared.resetForTesting()
        let suite = "AppStateFeatureRuntimeTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Defaults.register(in: defaults)

        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "a"
        )

        let inputMethods = InputMethodManager(
            tis: tis,
            scheduler: ImmediateScheduler(),
            notifications: FakeNotificationCenterClient()
        )
        let lockState = LockStateManager(userDefaults: defaults)
        let clipboardHistory = ClipboardHistoryManager(
            store: FRFakeStore(entries: []),
            userDefaults: defaults
        )

        FeatureRuntime.shared.register(.inputLock, manager: inputMethods)
        FeatureRuntime.shared.register(.inputLock, manager: lockState)
        FeatureRuntime.shared.register(.clipboardHistory, manager: clipboardHistory)

        let state = AppState(
            inputMethods: inputMethods,
            lockState: lockState,
            l10n: L10n(userDefaults: defaults),
            appearance: AppearanceSettings(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
            clipboardHistory: clipboardHistory,
            clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
            quickPhrases: QuickPhraseManager(store: FRFakePhraseStore()),
            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            userDefaults: defaults
        )

        state.selectInputSource(id: "b")
        XCTAssertEqual(state.selectedInputSourceID, "b")

        state.setLocked(true)
        XCTAssertTrue(state.lockState?.isLocked == true)
    }

    func test_setClipboardFeatureEnabled_triggersFeatureRuntimeSync() {
        FeatureRuntime.shared.resetForTesting()
        let suite = "AppStateFeatureRuntimeTests_clipboard"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Defaults.register(in: defaults)

        var syncCallCount = 0
        FeatureRuntime.shared.overrideBindingsForTesting { feature in
            if feature == .clipboardHistory {
                syncCallCount += 1
            }
        }

        let state = makeAppStateWithFeatureRuntime(defaults: defaults)

        // init 时 isClipboardFeatureEnabled 默认 true，syncAtLaunch 会触发一次 clipboardHistory binding
        let baseline = syncCallCount

        state.setClipboardFeatureEnabled(false)
        XCTAssertEqual(syncCallCount, baseline + 1)
        XCTAssertFalse(state.isClipboardFeatureEnabled)

        state.setClipboardFeatureEnabled(true)
        XCTAssertEqual(syncCallCount, baseline + 2)
        XCTAssertTrue(state.isClipboardFeatureEnabled)
    }
}

@MainActor
private func makeAppStateWithFeatureRuntime(
    defaults: UserDefaults
) -> AppState {
    let tis = FakeTISClient(
        inputSources: [
            .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
            .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
        ],
        currentID: "a"
    )

    let inputMethods = InputMethodManager(
        tis: tis,
        scheduler: ImmediateScheduler(),
        notifications: FakeNotificationCenterClient()
    )
    let lockState = LockStateManager(userDefaults: defaults)
    let clipboardHistory = ClipboardHistoryManager(
        store: FRFakeStore(entries: []),
        userDefaults: defaults
    )

    FeatureRuntime.shared.register(.inputLock, manager: inputMethods)
    FeatureRuntime.shared.register(.inputLock, manager: lockState)
    FeatureRuntime.shared.register(.clipboardHistory, manager: clipboardHistory)

    return AppState(
        inputMethods: inputMethods,
        lockState: lockState,
        l10n: L10n(userDefaults: defaults),
        appearance: AppearanceSettings(userDefaults: defaults),
        launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
        clipboardHistory: clipboardHistory,
        clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
        quickPhrases: QuickPhraseManager(store: FRFakePhraseStore()),
        monitor: makeFakeMonitor(),
        monitorPreferences: MonitorPreferences(userDefaults: defaults),
        userDefaults: defaults
    )
}

private final class FRFakeStore: ClipboardStore {
    private var entries: [ClipboardEntry]
    init(entries: [ClipboardEntry]) { self.entries = entries }
    var storageErrorMessage: String? { nil }
    func loadEntries() -> [ClipboardEntry] { entries }
    func saveEntry(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
    }
    func deleteEntries(ids: Set<UUID>) { entries.removeAll { ids.contains($0.id) } }
    func loadFullContent(for entryID: UUID) -> ClipboardContent? { entries.first { $0.id == entryID }?.content }
    func releaseMemory() {}
}

private final class FRFakePhraseStore: QuickPhraseStore {
    func loadPhrases() throws -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) throws {}
    func deletePhrase(id: UUID) throws {}
    func updatePhrase(_ phrase: QuickPhraseEntry) throws {}
    func releaseMemory() {}
}
