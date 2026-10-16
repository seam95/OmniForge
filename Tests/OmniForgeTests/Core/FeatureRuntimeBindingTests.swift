import XCTest
@testable import OmniForge

@MainActor
final class FeatureRuntimeBindingTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        // AppFeature.isAvailable 和 binding 都读取 UserDefaults.standard，
        // 所以测试必须直接操作 standard 而非自定义 suite
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        FeatureRuntime.shared.resetForTesting()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatureRuntimeBindingTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        UserDefaults.standard.removeObject(forKey: "OmniForge.monitorConfiguration")
        UserDefaults.standard.removeObject(forKey: "InputLock.monitorConfiguration")
        try? FileManager.default.removeItem(at: tmpDir)
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

    func test_tokenUsageBinding_startsWhenAvailable() {
        let manager = TokenUsageManager(preferences: TokenUsagePreferences(userDefaults: .standard))
        FeatureRuntime.shared.register(.tokenUsage, manager: manager)

        FeatureRuntime.shared.syncAtLaunch()

        XCTAssertTrue(manager.isActive)
    }

    func test_tokenUsageBinding_stopsWhenUnavailable() {
        let manager = TokenUsageManager(preferences: TokenUsagePreferences(userDefaults: .standard))
        FeatureRuntime.shared.register(.tokenUsage, manager: manager)

        FeatureRuntime.shared.syncAtLaunch()
        XCTAssertTrue(manager.isActive)

        FeatureRuntime.shared.setAvailable(.tokenUsage, false)
        XCTAssertFalse(manager.isActive)

        FeatureRuntime.shared.setAvailable(.tokenUsage, true)
        XCTAssertTrue(manager.isActive)
    }

    func test_tokenUsageBinding_noManager_doesNotCrash() {
        FeatureRuntime.shared.syncAtLaunch()
        FeatureRuntime.shared.setAvailable(.tokenUsage, false)
        FeatureRuntime.shared.setAvailable(.tokenUsage, true)
    }

    // MARK: - 供应商聚合接线

    /// 注入式聚合管理器（绕开 production 的真实路径，不写 ~/.claude 与 App Support）。
    private func makeAggregationManager() -> ProviderAggregationManager {
        ProviderAggregationManager(
            profileStore: BindingStubProfileStore(),
            backupStore: BindingStubBackupStore(),
            stackStore: AggregationStackStore(stackURL: tmpDir.appendingPathComponent("stack.json")),
            pendingStore: AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending.json")),
            loginStashStore: BindingStubLoginStashStore(),
            staleDetector: BindingStubStaleDetector(),
            proxy: BindingStubProxy(),
            claudeWriter: BindingStubClaudeWriter(),
            codexWriter: BindingStubCodexWriter(),
            profiles: [kimiProfile, glmProfile]
        )
    }

    private var kimiProfile: ProviderProfile {
        ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
        )
    }

    private var glmProfile: ProviderProfile {
        ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
        )
    }

    func test_providerSwitch_registersAggregationManagerAlongsideSwitchManager() {
        let runtime = FeatureRuntime.shared
        runtime.register(.providerSwitch, manager: ProviderSwitchManager.production(applicationSupportRoot: tmpDir))
        runtime.register(.providerSwitch, manager: makeAggregationManager())
        XCTAssertNotNil(runtime.manager(for: .providerSwitch, as: ProviderSwitchManager.self))
        XCTAssertNotNil(runtime.manager(for: .providerSwitch, as: ProviderAggregationManager.self))
    }

    func test_teardown_stopsAggregationProxy() throws {
        let runtime = FeatureRuntime.shared
        let manager = makeAggregationManager()
        runtime.register(.providerSwitch, manager: manager)
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        FeatureFactory().teardownSync(.providerSwitch, from: runtime)
        XCTAssertFalse(manager.isProxyRunning)
    }
}

// MARK: - 供应商聚合接线 stubs

private final class BindingStubProxy: AggregationProxying {
    var isRunning = false
    var resolvedPort: UInt16?
    var onUnexpectedStop: (() -> Void)?
    func start() throws {
        isRunning = true
        resolvedPort = 15721
    }
    func stop() {
        isRunning = false
        resolvedPort = nil
    }
}

private final class BindingStubProfileStore: ProviderProfileStoring {
    var stubProfiles: [ProviderProfile] = []
    func list(for tool: ProviderTool) -> [ProviderProfile] {
        stubProfiles.filter { $0.tool == tool }
    }
    func upsert(_ profile: ProviderProfile) throws {}
    func delete(_ profile: ProviderProfile) throws {}
    func adopt(name: String, tool: ProviderTool, baseURL: String, token: String, modelOverride: String?) throws -> ProviderProfile {
        ProviderProfile(id: "", name: name, tool: tool, baseURL: baseURL, token: token, modelOverride: modelOverride)
    }
}

private final class BindingStubBackupStore: ProviderBackupStoring {
    private var backups: [ProviderTool: [ProviderBackup]] = [:]
    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
        let backup = ProviderBackup(id: "stub-\(UUID().uuidString)", tool: tool, date: Date())
        backups[tool, default: []].insert(backup, at: 0)
        return backup
    }
    func list(tool: ProviderTool) -> [ProviderBackup] { backups[tool] ?? [] }
    func content(of backup: ProviderBackup) throws -> String { "" }
    func restore(_ backup: ProviderBackup, to configURL: URL) throws {}
}

private final class BindingStubLoginStashStore: CodexLoginStashStoring {
    var hasNativeLogin = false
    func stash() throws -> Bool { false }
    func restore() throws -> Bool { false }
    func discard() throws {}
}

private final class BindingStubStaleDetector: CodexStaleClientDetecting {
    func observe(catalogURL: URL, catalogIsOurs: Bool) {}
    func observeLogin(authURL: URL) {}
    func acknowledge(catalogURL: URL, authURL: URL) {}
    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? { nil }
}

private final class BindingStubClaudeWriter: AggregationClaudeConfigWriting {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) -> String { "" }
}

private final class BindingStubCodexWriter: AggregationCodexConfigWriting {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) -> String { "" }
}

private final class BindingTestStore: ClipboardStore {
    private var entries: [ClipboardEntry]
    init(entries: [ClipboardEntry]) { self.entries = entries }
    func loadEntries() -> [ClipboardEntry] { entries }
    func saveEntries(_ entries: [ClipboardEntry]) { self.entries = entries }
    func releaseMemory() {}
}
