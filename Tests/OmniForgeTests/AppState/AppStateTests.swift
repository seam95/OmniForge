import AppKit
import Combine
import XCTest
@testable import OmniForge

@MainActor
final class AppStateTests: XCTestCase {
    // MARK: - 启动 Dock policy

    /// 回归（2026-11-11）：LSUIElement=true 后，启动只允许 promotion 方向切换。
    /// 用户要求显示 Dock 图标时切 regular。
    func test_applyLaunchDockPolicy_promotesToRegular_whenDockIconVisible() {
        let suiteName = "AppStateTests_LaunchDock_Visible"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: UserDefaultsKeys.hideDockIcon)
        let app = NSApplication.shared

        AppState.applyLaunchDockPolicy(app: app, userDefaults: defaults)

        XCTAssertEqual(app.activationPolicy(), .regular)
    }

    /// 回归（2026-11-11）：隐藏开关开启时不得执行任何运行时 demotion。
    /// regular→accessory 在部分 macOS 版本静默失败且 getter 失真，图标会残留
    /// （steipete/CodexBar#4101），因此隐藏完全依赖 Info.plist 的 LSUIElement。
    func test_applyLaunchDockPolicy_keepsPolicy_whenHideDockIcon() {
        let suiteName = "AppStateTests_LaunchDock_Hidden"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: UserDefaultsKeys.hideDockIcon)
        let app = NSApplication.shared
        // 前置强制 regular，才能检测实现是否错误地执行了 demotion。
        app.setActivationPolicy(.regular)

        AppState.applyLaunchDockPolicy(app: app, userDefaults: defaults)

        XCTAssertEqual(
            app.activationPolicy(), .regular,
            "隐藏开关开启时启动不得调用 setActivationPolicy(.accessory)"
        )
    }

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

    /// SPEC §9.4.3：高频监控快照不再转发为控制中心根视图刷新信号
    /// （监控页经 MonitorContainerView 直连观察 manager 刷新）。
    func test_monitorSamplingChange_doesNotForwardAppStateChange() {
        let state = makeStateForObservation()
        var changeCount = 0
        let cancellable = state.objectWillChange.sink { changeCount += 1 }

        state.monitor?.setPanelDemand(.init(system: true, cpu: true))

        XCTAssertEqual(
            changeCount, 0,
            "监控采样更新不得转发为 AppState 根刷新（SPEC §9.4.3）"
        )
        withExtendedLifetime(cancellable) {}
    }

    /// SPEC §9.4：快捷短语列表更新不触发 AppState 根刷新
    /// （剪贴板浮窗的 QuickPhraseView 直连观察 manager）。
    func test_quickPhraseChange_doesNotForwardAppStateChange() {
        let state = makeStateForObservation()
        var changeCount = 0
        let cancellable = state.objectWillChange.sink { changeCount += 1 }

        state.quickPhrases?.add(content: "phrase")

        XCTAssertEqual(changeCount, 0)
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
            appearance: AppearanceSettings(userDefaults: defaults),
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
            appearance: AppearanceSettings(userDefaults: defaults),
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
            appearance: AppearanceSettings(userDefaults: defaults),
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
            appearance: AppearanceSettings(userDefaults: defaults),
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
            appearance: AppearanceSettings(userDefaults: defaults),
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
func makeStateForObservation() -> AppState {
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
        appearance: AppearanceSettings(userDefaults: defaults),
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

    var storageErrorMessage: String? { nil }

    func loadEntries() -> [ClipboardEntry] {
        entries
    }

    func saveEntry(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
    }

    func deleteEntries(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    func loadFullContent(for entryID: UUID) -> ClipboardContent? {
        entries.first { $0.id == entryID }?.content
    }

    func releaseMemory() {}
}

private final class FakeQuickPhraseStore: QuickPhraseStore {
    func loadPhrases() throws -> [QuickPhraseEntry] { [] }
    func savePhrase(_ phrase: QuickPhraseEntry) throws {}
    func deletePhrase(id: UUID) throws {}
    func updatePhrase(_ phrase: QuickPhraseEntry) throws {}
    func releaseMemory() {}
}
