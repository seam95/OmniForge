import Combine
import Foundation

/// 特性运行时 — 装载/卸载 Manager，并执行 binding。
/// availability 唯一读写源为注入的 `FeatureAvailabilityStoring`。
/// setAvailable 为异步事务：teardown 成功后才写 false；install 持久化成功后才 attach。
@MainActor
final class FeatureRuntime: ObservableObject {
    static let shared = FeatureRuntime()

    @Published private(set) var revision = 0
    @Published private(set) var phases: [AppFeature: FeatureAvailabilityPhase] = [:]

    private var loadedThisSession = Set<AppFeature>()
    private var managerRegistry: [String: Any] = [:]
    private var defaults: UserDefaults = .standard
    private var availabilityStore: FeatureAvailabilityStoring = UserDefaultsFeatureAvailabilityStore()
    private var factory: FeatureFactory?
    private var testingBindingsOverride: ((AppFeature) -> Void)?
    private var inFlight = Set<AppFeature>()
    /// persist false 失败时保留的 detached lease，供 retry。
    private var pausedLeases: [AppFeature: FeatureRegistrationLease] = [:]

    private init() {
        for feature in AppFeature.allCases {
            phases[feature] = .idle
            if availabilityStore.isAvailable(feature) {
                loadedThisSession.insert(feature)
            }
        }
    }

    private static func registryKey(_ feature: AppFeature, _ type: Any.Type) -> String {
        "\(feature.rawValue)::\(String(describing: type))"
    }

    // MARK: - 查询

    func isAvailable(_ feature: AppFeature) -> Bool {
        availabilityStore.isAvailable(feature)
    }

    var availableCount: Int {
        AppFeature.allCases.filter { isAvailable($0) }.count
    }

    func phase(for feature: AppFeature) -> FeatureAvailabilityPhase {
        phases[feature] ?? .idle
    }

    /// 仅在无 factory（无法真释放）且本会话卸过载时为 true。
    var needsRestartToUnload: Bool {
        factory == nil && loadedThisSession.contains { !isAvailable($0) }
    }

    // MARK: - Factory / store

    func configureFactory(_ factory: FeatureFactory) {
        self.factory = factory
    }

    func configureAvailabilityStore(_ store: FeatureAvailabilityStoring) {
        self.availabilityStore = store
        loadedThisSession = Set(AppFeature.allCases.filter { store.isAvailable($0) })
    }

    /// 启动：只 install + bind 已安装特性。
    func bootstrapInstalledFeatures() {
        for feature in AppFeature.allCases where isAvailable(feature) {
            factory?.install(feature, into: self)
            runBinding(for: feature)
        }
        loadedThisSession = Set(AppFeature.allCases.filter { isAvailable($0) })
        // bootstrap 是批量 install 的对偶：bump revision 驱动 AppState/StatusBar 等
        // 订阅方从 registry 重新拉取 Manager，避免启动后 manager 缺失与 availability 不同步。
        revision += 1
    }

    // MARK: - Manager 注册

    func register<T>(_ feature: AppFeature, manager: T) {
        let key = Self.registryKey(feature, T.self)
        managerRegistry[key] = manager
    }

    func manager<T>(for feature: AppFeature, as type: T.Type) -> T? {
        let key = Self.registryKey(feature, T.self)
        return managerRegistry[key] as? T
    }

    func unregisterAll(for feature: AppFeature) {
        let prefix = "\(feature.rawValue)::"
        managerRegistry = managerRegistry.filter { !$0.key.hasPrefix(prefix) }
    }

    /// 启动 compose 前清空注册表（不碰 availability）。
    func unregisterAllManagersForBootstrap() {
        managerRegistry.removeAll()
        pausedLeases.removeAll()
    }

    // MARK: - 生命周期

    func syncAtLaunch() {
        if factory != nil {
            bootstrapInstalledFeatures()
            return
        }
        for feature in AppFeature.allCases where isAvailable(feature) {
            runBinding(for: feature)
        }
    }

    func sync(_ features: [AppFeature]) {
        for feature in features where isAvailable(feature) {
            runBinding(for: feature)
        }
    }

    /// 同步入口：非 keepAwake 立即完成；keepAwake 卸载走 async 事务（调用方应 `setAvailableAsync`）。
    /// UI 新代码优先 `await setAvailableAsync`。
    func setAvailable(_ feature: AppFeature, _ available: Bool) {
        if feature == .keepAwake {
            Task { @MainActor in
                _ = await setAvailableAsync(feature, available)
            }
            return
        }
        // 同步路径：与历史测试兼容
        if inFlight.contains(feature) { return }
        let currently = isAvailable(feature)
        guard currently != available else { return }
        inFlight.insert(feature)
        defer { inFlight.remove(feature) }
        if available {
            _ = installTransactionSync(feature)
        } else {
            _ = uninstallTransactionSync(feature)
        }
    }

    /// 异步 availability 事务。失败时 availability 保持原值（除非已成功 persist）。
    @discardableResult
    func setAvailableAsync(
        _ feature: AppFeature,
        _ available: Bool
    ) async -> Result<Void, FeatureAvailabilityError> {
        if inFlight.contains(feature) {
            return .failure(.operationInProgress)
        }
        let currently = isAvailable(feature)
        guard currently != available else { return .success(()) }

        inFlight.insert(feature)
        defer { inFlight.remove(feature) }

        if available {
            return installTransactionSync(feature)
        } else if feature == .keepAwake {
            return await uninstallKeepAwakeTransaction()
        } else {
            return uninstallTransactionSync(feature)
        }
    }

    // MARK: - install / uninstall 事务

    private func installTransactionSync(_ feature: AppFeature) -> Result<Void, FeatureAvailabilityError> {
        phases[feature] = .installing

        // 1. Factory 先构造（persist 失败会卸掉）
        factory?.install(feature, into: self)

        // 2. 持久化 true
        do {
            try availabilityStore.setAvailable(feature, true)
        } catch {
            factory?.teardownSync(feature, from: self)
            unregisterAll(for: feature)
            phases[feature] = .failed("persist true failed")
            revision += 1
            return .failure(.persistenceFailed(String(describing: error)))
        }

        loadedThisSession.insert(feature)
        runBinding(for: feature)
        phases[feature] = .idle
        revision += 1
        return .success(())
    }

    private func uninstallTransactionSync(_ feature: AppFeature) -> Result<Void, FeatureAvailabilityError> {
        phases[feature] = .uninstalling

        // 有 factory：先停工 + teardown 卸注册；无 factory：兼容测试注入，仅 binding 停工，保留 registry。
        if factory != nil {
            runBindingStopping(feature)

            let prefix = "\(feature.rawValue)::"
            let detached = managerRegistry.filter { $0.key.hasPrefix(prefix) }
            let lease = FeatureRegistrationLease(
                feature: feature,
                managers: detached,
                isAttached: false
            )
            factory?.teardownSync(feature, from: self)
            pausedLeases[feature] = lease

            do {
                try availabilityStore.setAvailable(feature, false)
            } catch {
                reattach(lease)
                phases[feature] = .failed("persist false failed")
                revision += 1
                return .failure(.persistenceFailed(String(describing: error)))
            }

            pausedLeases.removeValue(forKey: feature)
            loadedThisSession.remove(feature)
        } else {
            // 无 factory：先写 false 再 binding，使 isAvailable 为 false；不 unregister。
            do {
                try availabilityStore.setAvailable(feature, false)
            } catch {
                phases[feature] = .failed("persist false failed")
                revision += 1
                return .failure(.persistenceFailed(String(describing: error)))
            }
            runBinding(for: feature)
            // loadedThisSession 保留，供 needsRestartToUnload 检测中途卸载。
        }

        phases[feature] = .idle
        revision += 1
        return .success(())
    }

    private func uninstallKeepAwakeTransaction() async -> Result<Void, FeatureAvailabilityError> {
        phases[.keepAwake] = .uninstalling

        if let manager = manager(for: .keepAwake, as: KeepAwakeManager.self) {
            await manager.shutdown(reason: .featureUninstall)
            if case .cleanupRequired = manager.state {
                phases[.keepAwake] = .failed("cleanup required after shutdown")
                revision += 1
                return .failure(.teardownFailed("keep-awake cleanup required"))
            }
        }
        manager(for: .keepAwake, as: KeepAwakeHotkeyManager.self)?.teardown()

        let prefix = "\(AppFeature.keepAwake.rawValue)::"
        let detached = managerRegistry.filter { $0.key.hasPrefix(prefix) }
        let lease = FeatureRegistrationLease(
            feature: .keepAwake,
            managers: detached,
            isAttached: false
        )
        unregisterAll(for: .keepAwake)
        pausedLeases[.keepAwake] = lease

        do {
            try availabilityStore.setAvailable(.keepAwake, false)
        } catch {
            reattach(lease)
            phases[.keepAwake] = .failed("persist false failed")
            revision += 1
            return .failure(.persistenceFailed(String(describing: error)))
        }

        pausedLeases.removeValue(forKey: .keepAwake)
        loadedThisSession.remove(.keepAwake)
        phases[.keepAwake] = .idle
        revision += 1
        return .success(())
    }

    private func runBindingStopping(_ feature: AppFeature) {
        // 对依赖 isAvailable 的 binding：先 teardown 侧停工接口
        switch feature {
        case .clipboardHistory:
            manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)?.stopMonitoring()
            manager(for: .clipboardHistory, as: ClipboardHotkeyManager.self)?.stopListening()
        case .systemMonitor:
            if let m = manager(for: .systemMonitor, as: SystemMonitorManager.self) {
                m.setPanelDemand(.none)
                m.setMenuBarMetrics([])
                m.setAlertRequirements([])
            }
        case .tokenUsage:
            manager(for: .tokenUsage, as: TokenUsageManager.self)?.stop()
            manager(for: .tokenUsage, as: DeepSeekBalanceManager.self)?.stop()
        case .shelf:
            manager(for: .shelf, as: ShelfService.self)?.syncWithPreferences()
        case .cleaner:
            CleanerScheduler.shared.stop()
        case .scrollInverter:
            ScrollInverter.shared.suspend()
        case .smoothScroll:
            SmoothScrollService.shared.suspend()
        case .mouseNavigation:
            MouseNavigationService.shared.suspend()
        case .dockClick:
            DockClickService.shared.suspend()
        case .screenshot:
            manager(for: .screenshot, as: ScreenshotFeatureManager.self)?.stopListening()
        default:
            break
        }
    }

    private func reattach(_ lease: FeatureRegistrationLease) {
        for (key, value) in lease.managers {
            managerRegistry[key] = value
        }
        lease.markAttached()
        // availability 仍为 true（persist 未成功）
    }

    // MARK: - binding

    private func runBinding(for feature: AppFeature) {
        if let override = testingBindingsOverride {
            override(feature)
            return
        }
        Self.bindings[feature]?()
    }

    private static let bindings: [AppFeature: () -> Void] = [
        .inputLock: {},
        .clipboardHistory: {
            let manager = shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)
            guard let manager else { return }
            let isAvailable = shared.isAvailable(.clipboardHistory)
            let defaults = shared.defaults
            let isEnabled = defaults.object(forKey: UserDefaultsKeys.clipboardFeatureEnabled) != nil
                ? defaults.bool(forKey: UserDefaultsKeys.clipboardFeatureEnabled)
                : true
            if isAvailable && isEnabled {
                manager.startMonitoring()
            } else {
                manager.stopMonitoring()
            }
        },
        .quickPhrase: {},
        .systemMonitor: {
            let manager = shared.manager(for: .systemMonitor, as: SystemMonitorManager.self)
            let prefs = shared.manager(for: .systemMonitor, as: MonitorPreferences.self)
            guard let manager else { return }
            let isEnabled = prefs?.configuration.isEnabled ?? true
            if shared.isAvailable(.systemMonitor), isEnabled {
                if let prefs {
                    manager.setMenuBarMetrics(prefs.configuration.enabledMenuBarMetrics)
                    manager.setAlertRequirements(
                        MonitorAlertManager.requiredMetrics(from: prefs.configuration.alert)
                    )
                    try? manager.setInterval(seconds: prefs.configuration.refreshInterval)
                }
            } else {
                manager.setPanelDemand(.none)
                manager.setMenuBarMetrics([])
                manager.setAlertRequirements([])
            }
        },
        .tokenUsage: {
            // availability 即启用：install 后启动调度，卸载时停止。
            if shared.isAvailable(.tokenUsage) {
                shared.manager(for: .tokenUsage, as: TokenUsageManager.self)?.start()
                shared.manager(for: .tokenUsage, as: DeepSeekBalanceManager.self)?.start()
            } else {
                shared.manager(for: .tokenUsage, as: TokenUsageManager.self)?.stop()
                shared.manager(for: .tokenUsage, as: DeepSeekBalanceManager.self)?.stop()
            }
        },
        .shelf: {
            shared.manager(for: .shelf, as: ShelfService.self)?.syncWithPreferences()
        },
        .launchAtLogin: {},
        .cleaner: {
            CleanerScheduler.shared.syncWithPreferences()
        },
        .uninstaller: {},
        .scrollInverter: { ScrollInverter.shared.syncWithPreferences() },
        .smoothScroll: { SmoothScrollService.shared.syncWithPreferences() },
        .mouseNavigation: { MouseNavigationService.shared.syncWithPreferences() },
        .dockClick: { DockClickService.shared.syncWithPreferences() },
        .keepAwake: {
            // binding：availability false 时注销快捷键；true 时由 composition root 接线
            if !shared.isAvailable(.keepAwake) {
                shared.manager(for: .keepAwake, as: KeepAwakeHotkeyManager.self)?.stopListening()
            }
        },
        .screenshot: {
            shared.manager(for: .screenshot, as: ScreenshotFeatureManager.self)?.syncWithPreferences()
        },
    ]

    // MARK: - 测试支持

    func setDefaultsForTesting(_ defaults: UserDefaults) {
        self.defaults = defaults
        self.availabilityStore = UserDefaultsFeatureAvailabilityStore(defaults: defaults)
    }

    func resetDefaultsForTesting() {
        self.defaults = .standard
        self.availabilityStore = UserDefaultsFeatureAvailabilityStore(defaults: .standard)
    }

    func resetForTesting() {
        managerRegistry.removeAll()
        testingBindingsOverride = nil
        defaults = .standard
        availabilityStore = UserDefaultsFeatureAvailabilityStore(defaults: .standard)
        factory = nil
        revision = 0
        inFlight.removeAll()
        pausedLeases.removeAll()
        phases = Dictionary(uniqueKeysWithValues: AppFeature.allCases.map { ($0, .idle) })
        loadedThisSession = Set(AppFeature.allCases.filter { availabilityStore.isAvailable($0) })
    }

    func overrideBindingsForTesting(_ handler: @escaping (AppFeature) -> Void) {
        testingBindingsOverride = handler
    }
}
