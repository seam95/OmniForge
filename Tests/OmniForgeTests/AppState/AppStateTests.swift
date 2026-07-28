import Combine
import XCTest
@testable import OmniForge

@MainActor
final class AppStateTests: XCTestCase {
    func test_clipboardEntryChangeDoesNotForwardAppStateChange() {
        let state = makeStateForObservation()
        var changeCount = 0
        let cancellable = state.objectWillChange.sink { changeCount += 1 }

        state.clipboardHistory?.addEntry(
            ClipboardEntry(
                id: UUID(),
                createdAt: Date(),
                type: .text,
                preview: "new",
                sourceAppBundleID: nil,
                sourceAppName: nil,
                content: .text("new")
            )
        )

        XCTAssertEqual(changeCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func test_monitorIsSamplingChange_forwardsObjectWillChange() {
        let state = makeStateForObservation()
        var changeCount = 0
        let cancellable = state.objectWillChange.sink { changeCount += 1 }

        state.monitor?.setPanelDemand(.init(system: true, cpu: true))

        XCTAssertGreaterThan(changeCount, 0, "AppState 应转发 SystemMonitorManager 的 objectWillChange")
        withExtendedLifetime(cancellable) {}
    }

    func test_monitorConfigurationChange_skipsReapplyWhenSystemMonitorUnavailable() {
        // isAvailable 读 standard，需在构造 AppState（订阅建立）前设为 false
        let previous = UserDefaults.standard.object(forKey: AppFeature.systemMonitor.availabilityKey)
        UserDefaults.standard.set(false, forKey: AppFeature.systemMonitor.availabilityKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppFeature.systemMonitor.availabilityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppFeature.systemMonitor.availabilityKey)
            }
        }

        let suiteName = "AppStateTests.monitorUnavailable"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitor = makeFakeMonitor()
        let prefs = MonitorPreferences(userDefaults: defaults)
        prefs.update {
            $0.enabledMenuBarMetrics = [.cpu]
            $0.alert.cpuEnabled = true
        }

        let state = AppState(
            inputMethods: InputMethodManager(
                tis: FakeTISClient(inputSources: [], currentID: "a"),
                scheduler: ImmediateScheduler(),
                notifications: FakeNotificationCenterClient()
            ),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
            clipboardHistory: ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults),
            clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
            quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),
            monitor: monitor,
            monitorPreferences: prefs,
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
            userDefaults: defaults
        )
        withExtendedLifetime(state) {}

        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.activeMenuBarMetrics.isEmpty)
        XCTAssertTrue(monitor.activeAlertRequirements.isEmpty)

        // 面板需求若仍被外部写入，配置重应用也应清回 .none
        monitor.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertTrue(monitor.isSampling)
        prefs.update {
            $0.enabledMenuBarMetrics = [.memory]
            $0.refreshInterval = 5
        }
        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.activeMenuBarMetrics.isEmpty)
    }

    func test_monitorConfigurationChange_skipsReapplyWhenIsEnabledFalse() {
        let previous = UserDefaults.standard.object(forKey: AppFeature.systemMonitor.availabilityKey)
        UserDefaults.standard.set(true, forKey: AppFeature.systemMonitor.availabilityKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppFeature.systemMonitor.availabilityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppFeature.systemMonitor.availabilityKey)
            }
        }

        let suiteName = "AppStateTests.monitorDisabled"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let monitor = makeFakeMonitor()
        let prefs = MonitorPreferences(userDefaults: defaults)
        prefs.update {
            $0.isEnabled = true
            $0.enabledMenuBarMetrics = [.cpu]
            $0.alert.cpuEnabled = true
        }

        let state = AppState(
            inputMethods: InputMethodManager(
                tis: FakeTISClient(inputSources: [], currentID: "a"),
                scheduler: ImmediateScheduler(),
                notifications: FakeNotificationCenterClient()
            ),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
            clipboardHistory: ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults),
            clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
            quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),
            monitor: monitor,
            monitorPreferences: prefs,
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
            userDefaults: defaults
        )
        withExtendedLifetime(state) {}

        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.activeMenuBarMetrics, [.cpu])

        prefs.update { $0.isEnabled = false }
        XCTAssertFalse(monitor.isSampling)
        XCTAssertTrue(monitor.activeMenuBarMetrics.isEmpty)
        XCTAssertTrue(monitor.activeAlertRequirements.isEmpty)

        // 禁用期间外部写入 panel demand 后，再改其他偏好仍应清回
        monitor.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertTrue(monitor.isSampling)
        prefs.update { $0.refreshInterval = 5 }
        XCTAssertFalse(monitor.isSampling)

        // 重新启用后从偏好恢复菜单栏/告警需求
        prefs.update { $0.isEnabled = true }
        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.activeMenuBarMetrics, [.cpu])
        XCTAssertEqual(
            monitor.activeAlertRequirements,
            MonitorAlertManager.requiredMetrics(from: prefs.configuration.alert)
        )
    }

    func test_selectAndLock_thenChangeAndNotification_correctsBackToLockedInputSource() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "b"
        )
        let notifications = FakeNotificationCenterClient()
        let scheduler = ImmediateScheduler()

        let suiteName = "AppStateTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let hotkeyManager = ClipboardHotkeyManager(userDefaults: defaults)

        let state = AppState(
            inputMethods: InputMethodManager(tis: tis, scheduler: scheduler, notifications: notifications),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
            clipboardHistory: ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults),
            clipboardHotkey: hotkeyManager,
            quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
            userDefaults: defaults
        )

        state.selectInputSource(id: "a")
        XCTAssertEqual(tis.currentInputSourceID(), "a")

        state.setLocked(true)
        XCTAssertEqual(state.lockState?.lockedInputSourceID, "a")

        XCTAssertTrue(tis.selectInputSource(id: "b"))
        XCTAssertEqual(tis.currentInputSourceID(), "b")

        notifications.post(name: .tisSelectedKeyboardInputSourceChanged)

        XCTAssertEqual(tis.currentInputSourceID(), "a")
        XCTAssertEqual(state.lockState?.lockedInputSourceID, "a")
        XCTAssertEqual(state.selectedInputSourceID, "a")
    }

    func test_stoppedInputLock_doesNotObserveInputSourceChanges() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "a"
        )
        let notifications = FakeNotificationCenterClient()
        let scheduler = ImmediateScheduler()

        let suiteName = "AppStateTests_unlocked"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let hotkeyManager = ClipboardHotkeyManager(userDefaults: defaults)

        let state = AppState(
            inputMethods: InputMethodManager(tis: tis, scheduler: scheduler, notifications: notifications),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
            clipboardHistory: ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults),
            clipboardHotkey: hotkeyManager,
            quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
            userDefaults: defaults
        )

        XCTAssertFalse(state.lockState?.isLocked == true)
        XCTAssertEqual(state.selectedInputSourceID, "a")
        XCTAssertFalse(state.inputMethods?.isObservingInputSourceChanges == true)

        XCTAssertTrue(tis.selectInputSource(id: "b"))
        notifications.post(name: .tisSelectedKeyboardInputSourceChanged)

        XCTAssertEqual(state.selectedInputSourceID, "a")
    }

    func test_unlocked_thenNotification_doesNotEnumerateInputSources() {
        let tis = FakeTISClient(
            inputSources: [
                .init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil),
                .init(id: "b", name: "B", isSelectable: true, isEnabled: true, icon: nil)
            ],
            currentID: "a"
        )
        let notifications = FakeNotificationCenterClient()
        let scheduler = ImmediateScheduler()

        let suiteName = "AppStateTests_noEnumerate"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let hotkeyManager = ClipboardHotkeyManager(userDefaults: defaults)

        let state = AppState(
            inputMethods: InputMethodManager(tis: tis, scheduler: scheduler, notifications: notifications),
            lockState: LockStateManager(userDefaults: defaults),
            l10n: L10n(userDefaults: defaults),
            launchAtLogin: LaunchAtLoginManager(client: FakeLaunchAtLoginClient(), userDefaults: defaults),
            clipboardHistory: ClipboardHistoryManager(store: FakeClipboardStore(entries: []), userDefaults: defaults),
            clipboardHotkey: hotkeyManager,
            quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
            userDefaults: defaults
        )

        XCTAssertFalse(state.lockState?.isLocked == true)
        let baseline = tis.listInputSourcesCallCount

        XCTAssertTrue(tis.selectInputSource(id: "b"))
        notifications.post(name: .tisSelectedKeyboardInputSourceChanged)

        XCTAssertEqual(state.selectedInputSourceID, "a")
        XCTAssertEqual(tis.listInputSourcesCallCount, baseline)
    }
}

@MainActor
private func makeStateForObservation() -> AppState {
    let defaults = UserDefaults(suiteName: "AppStateTests_observation")!
    defaults.removePersistentDomain(forName: "AppStateTests_observation")
    return AppState(
        inputMethods: InputMethodManager(
            tis: FakeTISClient(inputSources: [], currentID: "a"),
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
            store: FakeClipboardStore(entries: []),
            userDefaults: defaults
        ),
        clipboardHotkey: ClipboardHotkeyManager(userDefaults: defaults),
        quickPhrases: QuickPhraseManager(store: FakeQuickPhraseStore()),

            monitor: makeFakeMonitor(),
            monitorPreferences: MonitorPreferences(userDefaults: defaults),
            monitorAlerts: MonitorAlertManager(notificationClient: FakeAlertNotifier(), configuration: .init()),
        userDefaults: defaults
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
