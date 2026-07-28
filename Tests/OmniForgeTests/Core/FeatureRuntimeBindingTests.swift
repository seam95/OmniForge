import XCTest
@testable import OmniForge

@MainActor
final class FeatureRuntimeBindingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // AppFeature.isAvailable 和 binding 都读取 UserDefaults.standard，
        // 所以测试必须直接操作 standard 而非自定义 suite
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        FeatureRuntime.shared.resetForTesting()
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        UserDefaults.standard.removeObject(forKey: "OmniForge.monitorConfiguration")
        UserDefaults.standard.removeObject(forKey: "InputLock.monitorConfiguration")
        super.tearDown()
    }

    func test_clipboardHistoryBinding_startsMonitoringWhenAvailableAndEnabled() {
        let clipboardHistory = ClipboardHistoryManager(
            store: BindingTestStore(entries: []),
            userDefaults: .standard
        )
        FeatureRuntime.shared.register(.clipboardHistory, manager: clipboardHistory)

        // setUp 中已设置 available=true, enabled=true
        FeatureRuntime.shared.syncAtLaunch()

        XCTAssertTrue(clipboardHistory.isMonitoring)
    }

    func test_clipboardHistoryBinding_stopsMonitoringWhenUnavailable() {
        let clipboardHistory = ClipboardHistoryManager(
            store: BindingTestStore(entries: []),
            userDefaults: .standard
        )
        FeatureRuntime.shared.register(.clipboardHistory, manager: clipboardHistory)

        FeatureRuntime.shared.syncAtLaunch()
        XCTAssertTrue(clipboardHistory.isMonitoring)

        FeatureRuntime.shared.setAvailable(.clipboardHistory, false)
        XCTAssertFalse(clipboardHistory.isMonitoring)
    }

    func test_clipboardHistoryBinding_stopsMonitoringWhenDisabled() {
        let clipboardHistory = ClipboardHistoryManager(
            store: BindingTestStore(entries: []),
            userDefaults: .standard
        )
        FeatureRuntime.shared.register(.clipboardHistory, manager: clipboardHistory)

        FeatureRuntime.shared.syncAtLaunch()
        XCTAssertTrue(clipboardHistory.isMonitoring)

        UserDefaults.standard.set(false, forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        FeatureRuntime.shared.sync([.clipboardHistory])
        XCTAssertFalse(clipboardHistory.isMonitoring)
    }

    func test_clipboardHistoryBinding_noManager_doesNotCrash() {
        // 未注册 manager 时 binding 应安全跳过
        FeatureRuntime.shared.syncAtLaunch()
        // 不崩溃即通过
    }

    func test_inputLockBinding_doesNotCrash() {
        let tis = FakeTISClient(
            inputSources: [.init(id: "a", name: "A", isSelectable: true, isEnabled: true, icon: nil)],
            currentID: "a"
        )
        let inputMethods = InputMethodManager(
            tis: tis,
            scheduler: ImmediateScheduler(),
            notifications: FakeNotificationCenterClient()
        )
        let lockState = LockStateManager(userDefaults: .standard)

        FeatureRuntime.shared.register(.inputLock, manager: inputMethods)
        FeatureRuntime.shared.register(.inputLock, manager: lockState)

        FeatureRuntime.shared.syncAtLaunch()
        // 不崩溃即通过
    }

    // MARK: - systemMonitor binding

    func test_systemMonitorBinding_stopsManagerWhenUnavailable() {
        let manager = makeFakeMonitor()
        let prefs = MonitorPreferences(userDefaults: .standard)
        prefs.update {
            $0.enabledMenuBarMetrics = [.cpu]
            $0.alert.cpuEnabled = true
        }
        FeatureRuntime.shared.register(.systemMonitor, manager: manager)
        FeatureRuntime.shared.register(.systemMonitor, manager: prefs)

        FeatureRuntime.shared.syncAtLaunch()
        XCTAssertTrue(manager.isSampling)

        FeatureRuntime.shared.setAvailable(.systemMonitor, false)
        XCTAssertFalse(manager.isSampling)
        XCTAssertTrue(manager.activeMenuBarMetrics.isEmpty)
        XCTAssertTrue(manager.activeAlertRequirements.isEmpty)
    }

    func test_systemMonitorBinding_restoresFromPreferencesWhenAvailable() {
        let manager = makeFakeMonitor()
        let prefs = MonitorPreferences(userDefaults: .standard)
        prefs.update {
            $0.isEnabled = true
            $0.enabledMenuBarMetrics = [.memory]
            $0.refreshInterval = 5
            $0.alert.memoryEnabled = true
        }
        FeatureRuntime.shared.register(.systemMonitor, manager: manager)
        FeatureRuntime.shared.register(.systemMonitor, manager: prefs)

        FeatureRuntime.shared.setAvailable(.systemMonitor, false)
        XCTAssertFalse(manager.isSampling)
        XCTAssertTrue(manager.activeMenuBarMetrics.isEmpty)
        XCTAssertTrue(manager.activeAlertRequirements.isEmpty)

        FeatureRuntime.shared.setAvailable(.systemMonitor, true)
        XCTAssertTrue(manager.isSampling)
        XCTAssertEqual(manager.activeMenuBarMetrics, [.memory])
        XCTAssertEqual(
            manager.activeAlertRequirements,
            MonitorAlertManager.requiredMetrics(from: prefs.configuration.alert)
        )
        XCTAssertEqual(manager.activeRefreshInterval, 5)
    }

    func test_systemMonitorBinding_skipsRestoreWhenConfigurationDisabled() {
        let manager = makeFakeMonitor()
        let prefs = MonitorPreferences(userDefaults: .standard)
        prefs.update {
            $0.isEnabled = false
            $0.enabledMenuBarMetrics = [.cpu]
            $0.alert.cpuEnabled = true
        }
        FeatureRuntime.shared.register(.systemMonitor, manager: manager)
        FeatureRuntime.shared.register(.systemMonitor, manager: prefs)

        FeatureRuntime.shared.setAvailable(.systemMonitor, false)
        FeatureRuntime.shared.setAvailable(.systemMonitor, true)

        XCTAssertFalse(manager.isSampling)
        XCTAssertTrue(manager.activeMenuBarMetrics.isEmpty)
        XCTAssertTrue(manager.activeAlertRequirements.isEmpty)
    }

    func test_systemMonitorBinding_noManager_doesNotCrash() {
        // 未注册 manager 时 binding 应安全跳过
        FeatureRuntime.shared.syncAtLaunch()
        FeatureRuntime.shared.setAvailable(.systemMonitor, false)
        FeatureRuntime.shared.setAvailable(.systemMonitor, true)
    }

    func test_systemMonitor_defaultAvailabilityIsTrue() {
        // 与 inputLock 对齐：首次启动 featureAvailable.systemMonitor 默认为 true
        UserDefaults.standard.removeObject(forKey: AppFeature.systemMonitor.availabilityKey)
        Defaults.register()
        FeatureRuntime.shared.resetForTesting()
        XCTAssertTrue(FeatureRuntime.shared.isAvailable(.systemMonitor))
    }
}

private final class BindingTestStore: ClipboardStore {
    private var entries: [ClipboardEntry]
    init(entries: [ClipboardEntry]) { self.entries = entries }
    func loadEntries() -> [ClipboardEntry] { entries }
    func saveEntries(_ entries: [ClipboardEntry]) { self.entries = entries }
    func releaseMemory() {}
}
