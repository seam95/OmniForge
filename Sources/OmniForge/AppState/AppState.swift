import Combine
import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    /// 始终存在的轻量依赖
    let l10n: L10n
    let appearance: AppearanceSettings
    let launchAtLogin: LaunchAtLoginManager
    private let userDefaults: UserDefaults

    /// 按需特性：未安装时为 nil（不占运行时对象）
    private(set) var inputMethods: InputMethodManager?
    private(set) var lockState: LockStateManager?
    private(set) var clipboardHistory: ClipboardHistoryManager?
    private(set) var clipboardHotkey: ClipboardHotkeyManager?
    private(set) var quickPhrases: QuickPhraseManager?
    private(set) var monitor: SystemMonitorManager?
    private(set) var monitorPreferences: MonitorPreferences?
    private(set) var monitorAlerts: MonitorAlertManager?
    private(set) var fanPreferences: FanPreferences?
    private(set) var fanControl: FanControlCoordinator?
    private(set) var tokenUsageManager: TokenUsageManager?
    private(set) var tokenUsagePreferences: TokenUsagePreferences?
    private(set) var deepSeekBalanceManager: DeepSeekBalanceManager?
    private(set) var keepAwakeManager: KeepAwakeManager?
    private(set) var providerSwitchManager: ProviderSwitchManager?
    /// 始终装载；可由 composition root 注入。
    private(set) var clamshellRecoveryCoordinator: ClamshellRecoveryCoordinator?

    private var startClipboardMonitoring: () -> Void
    private var stopClipboardMonitoring: () -> Void

    @Published private(set) var inputSources: [InputSource] = []
    @Published private(set) var selectedInputSourceID: String?
    @Published private(set) var isClipboardFeatureEnabled: Bool
    @Published private(set) var hideDockIcon: Bool {
        didSet {
            userDefaults.set(hideDockIcon, forKey: UserDefaultsKeys.hideDockIcon)
            updateDockIconVisibility()
        }
    }
    private var cancellables = Set<AnyCancellable>()
    private var featureCancellables = Set<AnyCancellable>()
    private var hadAlertsEnabled = false
    private let bindToRuntime: Bool

    /// 生产路径：从 FeatureRuntime 取 Manager，revision 变化时重绑。
    convenience init(
        l10n: L10n,
        appearance: AppearanceSettings,
        launchAtLogin: LaunchAtLoginManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.init(
            l10n: l10n,
            appearance: appearance,
            launchAtLogin: launchAtLogin,
            inputMethods: nil,
            lockState: nil,
            clipboardHistory: nil,
            clipboardHotkey: nil,
            quickPhrases: nil,
            monitor: nil,
            monitorPreferences: nil,
            monitorAlerts: nil,
            userDefaults: userDefaults,
            bindToRuntime: true
        )
    }

    /// 测试 / 显式注入路径。appearance 必传非可选，保证调用方与
    /// AppState 观察的是同一 ObservableObject 实例，杜绝默认自建的幽灵实例。
    init(
        l10n: L10n,
        appearance: AppearanceSettings,
        launchAtLogin: LaunchAtLoginManager,
        inputMethods: InputMethodManager?,
        lockState: LockStateManager?,
        clipboardHistory: ClipboardHistoryManager?,
        clipboardHotkey: ClipboardHotkeyManager?,
        quickPhrases: QuickPhraseManager?,
        monitor: SystemMonitorManager?,
        monitorPreferences: MonitorPreferences?,
        monitorAlerts: MonitorAlertManager?,
        userDefaults: UserDefaults = .standard,
        startClipboardMonitoring: (() -> Void)? = nil,
        stopClipboardMonitoring: (() -> Void)? = nil,
        bindToRuntime: Bool = false
    ) {
        self.l10n = l10n
        self.appearance = appearance
        self.launchAtLogin = launchAtLogin
        self.inputMethods = inputMethods
        self.lockState = lockState
        self.clipboardHistory = clipboardHistory
        self.clipboardHotkey = clipboardHotkey
        self.quickPhrases = quickPhrases
        self.monitor = monitor
        self.monitorPreferences = monitorPreferences
        self.monitorAlerts = monitorAlerts
        self.userDefaults = userDefaults
        self.bindToRuntime = bindToRuntime
        self.startClipboardMonitoring = startClipboardMonitoring
            ?? { clipboardHistory?.startMonitoring() }
        self.stopClipboardMonitoring = stopClipboardMonitoring
            ?? { clipboardHistory?.stopMonitoring() }
        self.hideDockIcon = userDefaults.bool(forKey: UserDefaultsKeys.hideDockIcon)
        self.isClipboardFeatureEnabled = AppState.featureEnabled(
            for: UserDefaultsKeys.clipboardFeatureEnabled,
            in: userDefaults
        )

        if bindToRuntime {
            rebindFromRuntime()
        } else {
            wireFeatureSideEffects()
        }

        updateDockIconVisibility()
        forwardObjectWillChange(from: launchAtLogin)

        if bindToRuntime {
            FeatureRuntime.shared.$revision
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.rebindFromRuntime()
                }
                .store(in: &cancellables)
        }
    }

    /// 兼容旧测试签名（全量 Manager 非可选）。
    convenience init(
        inputMethods: InputMethodManager,
        lockState: LockStateManager,
        l10n: L10n,
        appearance: AppearanceSettings,
        launchAtLogin: LaunchAtLoginManager,
        clipboardHistory: ClipboardHistoryManager,
        clipboardHotkey: ClipboardHotkeyManager,
        quickPhrases: QuickPhraseManager,
        monitor: SystemMonitorManager,
        monitorPreferences: MonitorPreferences,
        monitorAlerts: MonitorAlertManager,
        userDefaults: UserDefaults = .standard,
        startClipboardMonitoring: (() -> Void)? = nil,
        stopClipboardMonitoring: (() -> Void)? = nil
    ) {
        self.init(
            l10n: l10n,
            appearance: appearance,
            launchAtLogin: launchAtLogin,
            inputMethods: inputMethods,
            lockState: lockState,
            clipboardHistory: clipboardHistory,
            clipboardHotkey: clipboardHotkey,
            quickPhrases: quickPhrases,
            monitor: monitor,
            monitorPreferences: monitorPreferences,
            monitorAlerts: monitorAlerts,
            userDefaults: userDefaults,
            startClipboardMonitoring: startClipboardMonitoring,
            stopClipboardMonitoring: stopClipboardMonitoring,
            bindToRuntime: false
        )
    }

    /// 由 composition root 注入始终装载的恢复协调器。
    func attachClamshellRecoveryCoordinator(_ coordinator: ClamshellRecoveryCoordinator) {
        clamshellRecoveryCoordinator = coordinator
        objectWillChange.send()
    }

    func rebindFromRuntime() {
        let runtime = FeatureRuntime.shared
        inputMethods = runtime.manager(for: .inputLock, as: InputMethodManager.self)
        lockState = runtime.manager(for: .inputLock, as: LockStateManager.self)
        clipboardHistory = runtime.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)
        clipboardHotkey = runtime.manager(for: .clipboardHistory, as: ClipboardHotkeyManager.self)
        quickPhrases = runtime.manager(for: .quickPhrase, as: QuickPhraseManager.self)
        monitor = runtime.manager(for: .systemMonitor, as: SystemMonitorManager.self)
        monitorPreferences = runtime.manager(for: .systemMonitor, as: MonitorPreferences.self)
        monitorAlerts = runtime.manager(for: .systemMonitor, as: MonitorAlertManager.self)
        fanPreferences = runtime.manager(for: .systemMonitor, as: FanPreferences.self)
        fanControl = runtime.manager(for: .systemMonitor, as: FanControlCoordinator.self)
        tokenUsageManager = runtime.manager(for: .tokenUsage, as: TokenUsageManager.self)
        tokenUsagePreferences = runtime.manager(for: .tokenUsage, as: TokenUsagePreferences.self)
        deepSeekBalanceManager = runtime.manager(for: .tokenUsage, as: DeepSeekBalanceManager.self)
        keepAwakeManager = runtime.manager(for: .keepAwake, as: KeepAwakeManager.self)
        providerSwitchManager = runtime.manager(for: .providerSwitch, as: ProviderSwitchManager.self)

        startClipboardMonitoring = { [weak self] in
            self?.clipboardHistory?.startMonitoring()
        }
        stopClipboardMonitoring = { [weak self] in
            self?.clipboardHistory?.stopMonitoring()
        }

        wireFeatureSideEffects()
        objectWillChange.send()
    }

    private func wireFeatureSideEffects() {
        featureCancellables.removeAll()

        // 转发范围（SPEC §9.4）：只转发壳层与设置窗仍以值传递消费的低频状态；
        // 高频监控快照、Token 更新、快捷短语与供应商列表不转发——控制中心各页面
        // 直接观察自身管理器，菜单栏指标走 StatusBarController 直连 Combine 管线，
        // 功能安装/卸载的解包身份变化由 rebindFromRuntime 的 objectWillChange 覆盖。
        if let lockState {
            forwardObjectWillChange(from: lockState, storeIn: &featureCancellables)
        }
        if let deepSeekBalanceManager {
            forwardObjectWillChange(from: deepSeekBalanceManager, storeIn: &featureCancellables)
        }
        if let keepAwakeManager {
            forwardObjectWillChange(from: keepAwakeManager, storeIn: &featureCancellables)
        }
        // 风扇控制的低频状态（抑制/曲线百分比）转发供设置窗回显；
        // 快照驱动的下发循环不产生 objectWillChange，不影响高频路径
        if let fanControl {
            forwardObjectWillChange(from: fanControl, storeIn: &featureCancellables)
        }

        refreshInputSources()
        selectedInputSourceID = lockState?.lockedInputSourceID
            ?? inputMethods?.currentInputSourceID()

        syncInputMethodRuntime()

        if isClipboardFeatureEnabled, FeatureRuntime.shared.isAvailable(.clipboardHistory) {
            startClipboardMonitoring()
        } else {
            stopClipboardMonitoring()
        }

        setupMonitorSubscriptions()
    }

    private func handleInputSourceChange() {
        guard let inputMethods, let lockState else { return }
        if lockState.isLocked {
            let lockedID = lockState.lockedInputSourceID
            selectedInputSourceID = lockedID ?? inputMethods.currentInputSourceID()
            inputMethods.correctIfNeeded(isLocked: true, lockedID: lockedID)
            return
        }
        selectedInputSourceID = inputMethods.currentInputSourceID()
    }

    func refreshInputSources() {
        let raw = inputMethods?.enumerateInputSources() ?? []
        // TIS 显示名跟随系统/进程语言；对齐到应用内 L10n，避免界面中文却显示 “Pinyin - Simplified”。
        inputSources = raw.map { InputSourceDisplayName.localized($0, language: l10n.language) }
    }

    func selectInputSource(id: String) {
        guard let inputMethods else { return }
        selectedInputSourceID = id
        _ = inputMethods.selectInputSource(id)
        if lockState?.isLocked == true {
            lockState?.lock(to: id)
        }
    }

    func setLocked(_ locked: Bool) {
        guard let lockState, let inputMethods else { return }
        guard locked != lockState.isLocked else { return }

        if locked {
            let targetID = selectedInputSourceID ?? inputMethods.currentInputSourceID()
            guard let targetID else { return }
            selectedInputSourceID = targetID
            _ = inputMethods.selectInputSource(targetID)
            lockState.lock(to: targetID)
        } else {
            lockState.unlock()
        }
        syncInputMethodRuntime()
    }

    var inputMethodRunState: FeatureRunState {
        guard lockState?.isLocked == true else { return .stopped }
        return inputMethods?.isObservingInputSourceChanges == true ? .running : .stopped
    }

    func retryInputMethod() {
        syncInputMethodRuntime()
    }

    func setHideDockIcon(_ hide: Bool) {
        guard hide != hideDockIcon else { return }
        hideDockIcon = hide
    }

    func setClipboardFeatureEnabled(_ enabled: Bool) {
        guard enabled != isClipboardFeatureEnabled else { return }
        isClipboardFeatureEnabled = enabled
        userDefaults.set(enabled, forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        FeatureRuntime.shared.sync([.clipboardHistory])
    }

    private func syncInputMethodRuntime() {
        guard let inputMethods, let lockState else { return }
        guard lockState.isLocked else {
            inputMethods.stopObservingInputSourceChanges()
            return
        }
        inputMethods.startObservingInputSourceChanges { [weak self] in
            self?.handleInputSourceChange()
        }
        inputMethods.correctIfNeeded(
            isLocked: true,
            lockedID: lockState.lockedInputSourceID
        )
    }

    private func updateDockIconVisibility() {
        guard !isRunningUnitTests else { return }
        guard let app = NSApp else { return }
        let policy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
        guard app.activationPolicy() != policy else { return }
        _ = app.setActivationPolicy(policy)
    }

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func featureEnabled(for key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return true }
        return userDefaults.bool(forKey: key)
    }

    private func forwardObjectWillChange(
        from manager: some ObservableObject,
        storeIn set: inout Set<AnyCancellable>
    ) {
        manager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &set)
    }

    private func forwardObjectWillChange(from manager: some ObservableObject) {
        forwardObjectWillChange(from: manager, storeIn: &cancellables)
    }

    private func setupMonitorSubscriptions() {
        guard let monitorPreferences, let monitor, let monitorAlerts else {
            hadAlertsEnabled = false
            return
        }

        monitorPreferences.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &featureCancellables)

        monitorPreferences.$configuration
            .removeDuplicates()
            .sink { [weak self] config in
                guard let self else { return }
                guard FeatureRuntime.shared.isAvailable(.systemMonitor), config.isEnabled else {
                    monitor.setPanelDemand(.none)
                    monitor.setMenuBarMetrics([])
                    monitor.setAlertRequirements([])
                    self.hadAlertsEnabled = false
                    return
                }
                try? monitor.setInterval(seconds: config.refreshInterval)
                monitor.setMenuBarMetrics(config.enabledMenuBarMetrics)
                monitorAlerts.updateConfiguration(config.alert)
                monitor.setAlertRequirements(
                    MonitorAlertManager.requiredMetrics(from: config.alert)
                )
                let hasAlerts = !MonitorAlertManager.requiredMetrics(from: config.alert).isEmpty
                if hasAlerts && !self.hadAlertsEnabled {
                    monitorAlerts.requestAuthorization()
                }
                self.hadAlertsEnabled = hasAlerts
            }
            .store(in: &featureCancellables)

        monitor.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let monitorAlerts = self.monitorAlerts else { return }
                _ = monitorAlerts.evaluate(snapshot, at: Date())
            }
            .store(in: &featureCancellables)
    }
}
