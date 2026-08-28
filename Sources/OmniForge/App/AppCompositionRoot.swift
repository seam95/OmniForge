import AppKit
import Combine
import Foundation

/// 启动编排阶段：恢复完成前 UI 不应暴露可操作保持唤醒开关。
enum AppBootstrapPhase: Equatable {
    case waitingForClamshellRecovery
    case ready
    case recoveryBlocked
}

/// 组合根 — 只装载 available 特性，避免启动全量 Manager。
@MainActor
final class AppCompositionRoot {
    let appState: AppState
    let statusBarController: StatusBarController
    /// 始终装载，独立于 Feature availability。
    let clamshellRecoveryCoordinator: ClamshellRecoveryCoordinator
    @Published private(set) var bootstrapPhase: AppBootstrapPhase = .waitingForClamshellRecovery
    private let userDefaults: UserDefaults

    private var sinks = Set<AnyCancellable>()

    init(
        appState: AppState,
        statusBarController: StatusBarController,
        clamshellRecoveryCoordinator: ClamshellRecoveryCoordinator,
        bootstrapPhase: AppBootstrapPhase = .ready,
        userDefaults: UserDefaults = .standard
    ) {
        self.appState = appState
        self.statusBarController = statusBarController
        self.clamshellRecoveryCoordinator = clamshellRecoveryCoordinator
        self.bootstrapPhase = bootstrapPhase
        self.userDefaults = userDefaults
    }

    /// 测试与兼容入口：同步 bootstrap 已安装特性（不等待合盖恢复）。
    static func compose(userDefaults: UserDefaults = .standard) -> AppCompositionRoot {
        let foundation = makeFoundation(userDefaults: userDefaults)
        // 跳过 recoverOnLaunch 时须解除默认 blocksKeepAwakeStart，否则会话永远无法 start。
        foundation.recoveryCoordinator.releaseStartGateWithoutRecovery()
        foundation.runtimeBootstrap()
        // 必须在 bootstrap 之后创建 AppState/StatusBar：它们在 init 时从 registry 取 Manager。
        let ui = makeUIParts(userDefaults: foundation.userDefaults)
        let root = AppCompositionRoot(
            appState: ui.appState,
            statusBarController: ui.statusBarController,
            clamshellRecoveryCoordinator: foundation.recoveryCoordinator,
            bootstrapPhase: .ready,
            userDefaults: foundation.userDefaults
        )
        root.finishWiring()
        return root
    }

    /// 生产启动：先合盖恢复，成功后再 bootstrap FeatureRuntime。
    static func composeAfterClamshellRecovery(
        userDefaults: UserDefaults = .standard
    ) async -> AppCompositionRoot {
        let foundation = makeFoundation(userDefaults: userDefaults)
        // 恢复不依赖 AppState/StatusBar；在 UI 创建前完成。
        await foundation.recoveryCoordinator.recoverOnLaunch()
        let phase: AppBootstrapPhase
        if foundation.recoveryCoordinator.blocksKeepAwakeStart {
            // 恢复失败/冲突：仍 bootstrap 其他特性，但标记 blocked，禁止 keep-awake auto start。
            phase = .recoveryBlocked
        } else {
            phase = .ready
        }
        foundation.runtimeBootstrap()
        // 必须在 bootstrap 之后创建 AppState/StatusBar：它们在 init 时从 registry 取 Manager。
        let ui = makeUIParts(userDefaults: foundation.userDefaults)
        let root = AppCompositionRoot(
            appState: ui.appState,
            statusBarController: ui.statusBarController,
            clamshellRecoveryCoordinator: foundation.recoveryCoordinator,
            bootstrapPhase: phase,
            userDefaults: foundation.userDefaults
        )
        root.finishWiring()
        return root
    }

    /// App 退出：先终止 dsh web 子进程（独立无依赖），再优先 KeepAwakeManager.shutdown；
    /// 无 Manager 时走 Coordinator 恢复。
    func prepareForApplicationTermination() async -> Bool {
        DSHWebManager.shared.shutdown()
        // 便签：失效全部唤起定时器并撤销通知请求（窗口随 teardown 关闭）。
        FeatureRuntime.shared.manager(for: .stickyNotes, as: StickyNoteManager.self)?.teardown()
        if let manager = FeatureRuntime.shared.manager(for: .keepAwake, as: KeepAwakeManager.self) {
            await manager.shutdown(reason: .applicationTermination)
            if case .cleanupRequired = manager.state {
                return false
            }
            return true
        }
        return await clamshellRecoveryCoordinator.prepareForApplicationTermination()
    }

    // MARK: - private construction

    /// 与 UI 无关的启动基础：Defaults / 合盖恢复 / factory bootstrap 入口。
    @MainActor
    private struct FoundationParts {
        let userDefaults: UserDefaults
        let recoveryCoordinator: ClamshellRecoveryCoordinator
        let clamshellController: ClamshellControlling
        let clamshellStore: ClamshellRecoveryStore

        func runtimeBootstrap() {
            // 与 recoveryCoordinator 共用同一 controller/store，避免设置页授权与启动恢复分裂。
            let factory = FeatureFactory(
                userDefaults: userDefaults,
                clamshellController: clamshellController,
                clamshellStore: clamshellStore,
                blocksStart: { [recoveryCoordinator] in
                    recoveryCoordinator.blocksKeepAwakeStart
                }
            )
            FeatureRuntime.shared.configureFactory(factory)
            FeatureRuntime.shared.setDefaultsForTesting(userDefaults)
            FeatureRuntime.shared.unregisterAllManagersForBootstrap()
            FeatureRuntime.shared.bootstrapInstalledFeatures()
        }
    }

    /// 依赖 FeatureRuntime registry 的 UI 侧对象。
    @MainActor
    private struct UIParts {
        let appState: AppState
        let statusBarController: StatusBarController
    }

    private static func makeFoundation(userDefaults: UserDefaults) -> FoundationParts {
        Defaults.register(in: userDefaults)

        if userDefaults.bool(forKey: UserDefaultsKeys.hideDockIcon) {
            NSApp?.setActivationPolicy(.accessory)
        }

        let recoveryStore: ClamshellRecoveryStore
        if let store = try? ClamshellRecoveryStore.production() {
            recoveryStore = store
        } else {
            // 测试/异常环境：使用临时目录，避免启动失败。
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("omniforge-recovery-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            recoveryStore = ClamshellRecoveryStore(applicationSupportRoot: temp)
        }

        let runner = ProcessCommandRunner()
        let userName = NSUserName()
        let uid = getuid()
        let clamshell = ClamshellController(runner: runner, userName: userName, uid: uid)
        let recoveryCoordinator = ClamshellRecoveryCoordinator(
            store: recoveryStore,
            controller: clamshell,
            userName: userName,
            uid: uid
        )

        return FoundationParts(
            userDefaults: userDefaults,
            recoveryCoordinator: recoveryCoordinator,
            clamshellController: clamshell,
            clamshellStore: recoveryStore
        )
    }

    private static func makeUIParts(userDefaults: UserDefaults) -> UIParts {
        let l10n = L10n(userDefaults: userDefaults)
        let launchAtLogin = LaunchAtLoginManager(
            client: ServiceManagementLaunchAtLoginClient(),
            userDefaults: userDefaults
        )
        // 此时 FeatureRuntime registry 已装载 available 特性的 Manager。
        let appState = AppState(
            l10n: l10n,
            launchAtLogin: launchAtLogin,
            userDefaults: userDefaults
        )

        let clipboardWindowController = ClipboardWindowController(state: appState)
        let statusBarController = StatusBarController(
            state: appState,
            clipboardWindowController: clipboardWindowController,
            onOpenSettings: { tab in
                (NSApp.delegate as? AppDelegate)?.openSettings(tab: tab)
            }
        )

        return UIParts(
            appState: appState,
            statusBarController: statusBarController
        )
    }

    /// 共享接线：recovery 注入、hotkey/shelf 绑定、revision 订阅。
    private func finishWiring() {
        appState.attachClamshellRecoveryCoordinator(clamshellRecoveryCoordinator)
        wireShelfAnchor()
        wireClipboardHotkey()
        wireKeepAwakeHotkey()
        // autoStart 只在首次接线触发，不进入 revision 重绑，避免权限变化时重复启动。
        wireKeepAwakeAutoStart()
        wireScreenshotHotkeys()
        wireStickyNotesHotkey()
        observeRuntimeRevision()
    }

    private func observeRuntimeRevision() {
        FeatureRuntime.shared.$revision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.wireShelfAnchor()
                self?.wireClipboardHotkey()
                self?.wireKeepAwakeHotkey()
                self?.wireScreenshotHotkeys()
                self?.wireStickyNotesHotkey()
            }
            .store(in: &sinks)
    }

    private func wireShelfAnchor() {
        guard let shelf = FeatureRuntime.shared.manager(for: .shelf, as: ShelfService.self) else {
            return
        }
        shelf.statusItemFrameProvider = { [weak statusBarController] in
            statusBarController?.mainStatusItemScreenFrame()
        }
    }

    private func wireClipboardHotkey() {
        guard let hotkeyManager = appState.clipboardHotkey else { return }
        hotkeyManager.startListening { [weak self] in
            guard let self else { return }
            guard self.appState.isClipboardFeatureEnabled,
                  FeatureRuntime.shared.isAvailable(.clipboardHistory) else { return }
            self.statusBarController.showClipboardPanel()
        }
    }

    private func wireKeepAwakeHotkey() {
        guard let hotkey = FeatureRuntime.shared.manager(
            for: .keepAwake,
            as: KeepAwakeHotkeyManager.self
        ) else { return }
        guard let manager = FeatureRuntime.shared.manager(
            for: .keepAwake,
            as: KeepAwakeManager.self
        ) else { return }
        hotkey.startListening { [weak manager] in
            manager?.toggle()
        }
        hotkey.syncRegistrationWithGates()
    }

    /// 启动时若配置了 autoStart，则自动开启保持唤醒。
    /// 合盖恢复阻塞 / feature 不可用时跳过；`start()` 本身幂等静默失败。
    private func wireKeepAwakeAutoStart() {
        guard bootstrapPhase == .ready else { return }
        guard FeatureRuntime.shared.isAvailable(.keepAwake) else { return }
        guard let manager = FeatureRuntime.shared.manager(
            for: .keepAwake,
            as: KeepAwakeManager.self
        ) else { return }

        let autoStart: Bool
        do {
            autoStart = try KeepAwakeConfiguration(userDefaults: userDefaults).load().autoStart
        } catch {
            return
        }
        guard autoStart else { return }
        manager.start()
    }

    /// 截图快捷键：feature 不可用时 syncWithPreferences 会停监听，避免残留全局快捷键。
    private func wireScreenshotHotkeys() {
        guard let manager = FeatureRuntime.shared.manager(
            for: .screenshot,
            as: ScreenshotFeatureManager.self
        ) else { return }
        manager.syncWithPreferences()
    }

    /// 便签「新建」快捷键：feature 不可用时注销，避免残留全局快捷键。
    private func wireStickyNotesHotkey() {
        guard let manager = FeatureRuntime.shared.manager(
            for: .stickyNotes,
            as: StickyNoteManager.self
        ) else { return }
        manager.syncHotkeyWithAvailability()
    }
}
