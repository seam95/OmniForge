import ApplicationServices
import CoreGraphics
import Foundation

/// 按需创建特性依赖。只在 install 时分配对象，避免启动全量 new。
@MainActor
struct FeatureFactory {
    let userDefaults: UserDefaults
    /// 与 ClamshellRecoveryCoordinator 共用同一 controller，保证命令串行与授权探测一致。
    let clamshellController: ClamshellControlling?
    let clamshellStore: ClamshellRecoveryStore?
    /// 启动门禁（如合盖恢复未完成）；由 composition root 注入。
    let blocksStart: () -> Bool

    init(
        userDefaults: UserDefaults = .standard,
        clamshellController: ClamshellControlling? = nil,
        clamshellStore: ClamshellRecoveryStore? = nil,
        blocksStart: @escaping () -> Bool = { false }
    ) {
        self.userDefaults = userDefaults
        self.clamshellController = clamshellController
        self.clamshellStore = clamshellStore
        self.blocksStart = blocksStart
    }

    /// 创建并注册该特性的 Manager；若已注册则跳过（幂等）。
    func install(_ feature: AppFeature, into runtime: FeatureRuntime) {
        switch feature {
        case .inputLock:
            if runtime.manager(for: .inputLock, as: InputMethodManager.self) == nil {
                let input = InputMethodManager(tis: CarbonTISClient())
                runtime.register(.inputLock, manager: input)
            }
            if runtime.manager(for: .inputLock, as: LockStateManager.self) == nil {
                runtime.register(.inputLock, manager: LockStateManager(userDefaults: userDefaults))
            }
        case .clipboardHistory:
            if runtime.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self) == nil {
                runtime.register(
                    .clipboardHistory,
                    manager: ClipboardHistoryManager(userDefaults: userDefaults)
                )
            }
            if runtime.manager(for: .clipboardHistory, as: ClipboardHotkeyManager.self) == nil {
                runtime.register(
                    .clipboardHistory,
                    manager: ClipboardHotkeyManager(userDefaults: userDefaults)
                )
            }
        case .quickPhrase:
            if runtime.manager(for: .quickPhrase, as: QuickPhraseManager.self) == nil {
                runtime.register(.quickPhrase, manager: QuickPhraseManager())
            }
        case .systemMonitor:
            if runtime.manager(for: .systemMonitor, as: SystemMonitorManager.self) == nil {
                runtime.register(.systemMonitor, manager: Self.makeProductionMonitor())
            }
            if runtime.manager(for: .systemMonitor, as: MonitorPreferences.self) == nil {
                runtime.register(
                    .systemMonitor,
                    manager: MonitorPreferences(userDefaults: userDefaults)
                )
            }
            if runtime.manager(for: .systemMonitor, as: MonitorAlertManager.self) == nil {
                let l10n = L10n(userDefaults: userDefaults)
                runtime.register(
                    .systemMonitor,
                    manager: MonitorAlertManager(
                        notificationClient: UserNotificationMonitorClient(),
                        configuration: .init(),
                        stringsProvider: { l10n.s }
                    )
                )
            }
        case .shelf:
            if runtime.manager(for: .shelf, as: ShelfService.self) == nil {
                runtime.register(.shelf, manager: ShelfService(userDefaults: userDefaults))
            }
        case .launchAtLogin:
            // 极轻量，由 AppState/通用设置持有即可，不进重特性工厂
            break
        case .cleaner:
            // 工具型特性，无后台 Manager 需注册；调度器随可用性启停。
            CleanerScheduler.shared.syncWithPreferences()
        case .uninstaller:
            // 工具型特性，按需触发，无后台工作
            break
        case .colorPicker:
            // 工具型特性，系统 NSColorSampler 即用即取，无后台 Manager
            break
        case .networkDiagnostics:
            // 工具型特性：按需采集，无后台 Manager
            break
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick:
            // 进程级单例（系统内只能有一个事件 tap），不进注册表；
            // 启停由 FeatureRuntime bindings 调用各自 syncWithPreferences。
            break
        case .keepAwake:
            if runtime.manager(for: .keepAwake, as: KeepAwakeManager.self) == nil {
                let config = KeepAwakeConfiguration(userDefaults: userDefaults)
                let clock = SystemKeepAwakeClock()
                let scheduler = KeepAwakeScheduler(clock: clock)
                let assertions = PowerAssertionController()
                let powerReader = PowerSourceReader()
                let pointerPoster = PointerActivityPoster()
                let pointerService = PointerActivityService(
                    poster: pointerPoster,
                    scheduler: scheduler,
                    clock: clock,
                    isAccessibilityTrusted: { Permissions.shared.accessibility }
                )
                let manager = KeepAwakeManager(
                    assertions: assertions,
                    powerReader: powerReader,
                    scheduler: scheduler,
                    clock: clock,
                    configuration: { try config.load() },
                    notifications: UserNotificationMonitorClient(),
                    pointerService: pointerService,
                    isFeatureAvailable: { FeatureRuntime.shared.isAvailable(.keepAwake) },
                    blocksStart: blocksStart,
                    clamshellController: clamshellController,
                    clamshellStore: clamshellStore
                )
                runtime.register(.keepAwake, manager: manager)
            }
            if runtime.manager(for: .keepAwake, as: KeepAwakeHotkeyManager.self) == nil {
                let registrar = CarbonHotkeyRegistrar()
                let hotkey = KeepAwakeHotkeyManager(
                    registrar: registrar,
                    userDefaults: userDefaults,
                    isFeatureAvailable: { FeatureRuntime.shared.isAvailable(.keepAwake) },
                    isHotkeyPreferenceEnabled: {
                        if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeShortcutEnabled) == nil {
                            return true
                        }
                        return userDefaults.bool(forKey: UserDefaultsKeys.keepAwakeShortcutEnabled)
                    },
                    canToggle: {
                        guard let manager = FeatureRuntime.shared.manager(
                            for: .keepAwake,
                            as: KeepAwakeManager.self
                        ) else {
                            return .failure(.featureUnavailable)
                        }
                        switch manager.state {
                        case .activating, .deactivating, .cleanupRequired:
                            return .failure(.operationInProgress)
                        case .inactive, .active:
                            return .success(())
                        }
                    }
                )
                runtime.register(.keepAwake, manager: hotkey)
            }
        case .screenshot:
            if runtime.manager(for: .screenshot, as: ScreenshotFeatureManager.self) == nil {
                let captureClient: ScreenCaptureClient = ScreenCaptureKitClient(
                    preflightAccess: {
                        Permissions.shared.screenRecording || CGPreflightScreenCaptureAccess()
                    }
                )
                // 阶段 5 输出子系统：创建编码 / 剪贴板 / 保存实例，透传到编辑器。
                let outputEncoder = ImageOutputEncoder()
                let clipboardWriter = ClipboardImageWriter()
                let screenshotSaver = ScreenshotSaver()
                let outputConfiguration = ScreenshotOutputConfiguration(userDefaults: userDefaults)
                let overlayController = CaptureOverlayController(
                    captureClient: captureClient,
                    outputEncoder: outputEncoder,
                    clipboardWriter: clipboardWriter,
                    screenshotSaver: screenshotSaver,
                    outputConfigurationProvider: { outputConfiguration.load() }
                )
                let recordingCoordinator = RecordingSessionCoordinator(
                    userDefaults: userDefaults,
                    stringsProvider: { L10n(userDefaults: userDefaults).s }
                )
                let manager = ScreenshotFeatureManager(
                    userDefaults: userDefaults,
                    isFeatureAvailable: { FeatureRuntime.shared.isAvailable(.screenshot) },
                    isScreenRecordingGranted: { Permissions.shared.screenRecording },
                    stringsProvider: { L10n(userDefaults: userDefaults).s },
                    captureClient: captureClient,
                    overlayController: overlayController,
                    recordingCoordinator: recordingCoordinator
                )
                let pipeline = ScreenshotResultPipeline(
                    userDefaults: userDefaults,
                    encoder: outputEncoder,
                    clipboardWriter: clipboardWriter,
                    saver: screenshotSaver,
                    outputConfigurationProvider: { outputConfiguration.load() }
                )
                let pinRegistry = PinnedScreenshotRegistry(pipeline: pipeline)
                pinRegistry.stringsProvider = { L10n(userDefaults: userDefaults).s }
                let pinBridge = PinnedScreenshotPipelineBridge(registry: pinRegistry)
                pipeline.pinService = pinBridge
                // 阶段 5：把钉图服务透传给编辑器（pinResultBuilder 由 overlay
                // 用屏幕上下文构造，阶段 6 美化接线点在此）。
                overlayController.setPinService(pinBridge)
                manager.pinnedScreenshotRegistry = pinRegistry
                manager.pinPipelineBridge = pinBridge
                runtime.register(.screenshot, manager: manager)
            }
        }
    }

    /// 同步 teardown（非 keepAwake 立即成功）。
    func teardown(_ feature: AppFeature, from runtime: FeatureRuntime) {
        teardownSync(feature, from: runtime)
    }

    /// 可等待 teardown；keepAwake 走 Manager.shutdown。
    func teardownAsync(_ feature: AppFeature, from runtime: FeatureRuntime) async throws {
        if feature == .keepAwake {
            if let manager = runtime.manager(for: .keepAwake, as: KeepAwakeManager.self) {
                await manager.shutdown(reason: .featureUninstall)
                if case .cleanupRequired = manager.state {
                    throw FeatureAvailabilityError.teardownFailed("keep-awake cleanup required")
                }
            }
            runtime.manager(for: .keepAwake, as: KeepAwakeHotkeyManager.self)?.teardown()
            runtime.unregisterAll(for: feature)
            return
        }
        teardownSync(feature, from: runtime)
    }

    /// 停止后台工作并卸注册，释放强引用。
    func teardownSync(_ feature: AppFeature, from runtime: FeatureRuntime) {
        switch feature {
        case .inputLock:
            runtime.manager(for: .inputLock, as: InputMethodManager.self)?
                .stopObservingInputSourceChanges()
        case .clipboardHistory:
            runtime.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)?
                .stopMonitoring()
            runtime.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)?
                .releaseMemory()
            runtime.manager(for: .clipboardHistory, as: ClipboardHotkeyManager.self)?
                .stopListening()
        case .quickPhrase:
            runtime.manager(for: .quickPhrase, as: QuickPhraseManager.self)?
                .releaseMemory()
        case .systemMonitor:
            if let manager = runtime.manager(for: .systemMonitor, as: SystemMonitorManager.self) {
                manager.setPanelDemand(.none)
                manager.setMenuBarMetrics([])
                manager.setAlertRequirements([])
            }
        case .shelf:
            runtime.manager(for: .shelf, as: ShelfService.self)?.syncWithPreferences()
        case .launchAtLogin:
            break
        case .cleaner:
            CleanerScheduler.shared.stop()
        case .uninstaller:
            break
        case .colorPicker:
            break
        case .networkDiagnostics:
            break
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick:
            // 单例自管理：先停 tap 再卸载，避免权限撤销后残留活跃 tap
            switch feature {
            case .scrollInverter: ScrollInverter.shared.suspend()
            case .smoothScroll: SmoothScrollService.shared.suspend()
            case .mouseNavigation: MouseNavigationService.shared.suspend()
            case .dockClick: DockClickService.shared.suspend()
            default: break
            }
        case .keepAwake:
            break
        case .screenshot:
            runtime.manager(for: .screenshot, as: ScreenshotFeatureManager.self)?.teardown()
        }
        runtime.unregisterAll(for: feature)
    }

    private static func makeProductionMonitor() -> SystemMonitorManager {
        SystemMonitorManager(
            scheduler: TimerRepeatingScheduler(),
            cpuSampler: CPUUsageSampler(),
            gpuSampler: GPUUsageSampler(),
            memorySampler: MemorySampler(),
            temperatureSampler: TemperatureSampler(smc: SMCClient()),
            networkSampler: NetworkSampler(),
            diskSampler: DiskSampler(),
            powerSampler: PowerSampler(smc: SMCClient()),
            peripheralBatterySampler: PeripheralBatterySampler(),
            processSampler: ProcessUsageSampler()
        )
    }
}
