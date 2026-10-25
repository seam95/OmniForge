import AppKit
import Combine
import os.log

/// 应用代理 — 管理 AppKit 生命周期。
/// 启动：合盖恢复优先于 FeatureRuntime bootstrap。
/// 退出：`terminateLater` + 单一 shutdown 事务。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MainMenuSettingsTarget {

    private static let logger = Logger(subsystem: "com.omniforge.app", category: "AppDelegate")

    /// 组合根，在 applicationDidFinishLaunching 中创建并持有
    var compositionRoot: AppCompositionRoot?

    /// 设置窗口管理器
    var settingsWindowManager: SettingsWindowManager?

    private var cancellables = Set<AnyCancellable>()
    private let instanceLease: SingleInstanceLease?
    private let wakeNotifications: NotificationCenterClient
    private var wakeObserver: AnyObject?
    private var pendingSettingsWake = false

    /// 退出事务：重复 Quit 复用同一 Task。
    private var terminationTask: Task<Bool, Never>?
    /// 清理进行中（测试可观察）。
    private(set) var isTerminating = false
    /// 清理已成功完成：下一次 terminate 直接放行（cancel-then-retry 模型的第二段）。
    private(set) var hasCompletedTerminationCleanup = false
    /// 清理完成后的再次终止动作。生产为 `NSApp.terminate(nil)`；
    /// 测试注入空实现，避免 XCTest 进程被真实终止。
    var terminateAction: @MainActor () -> Void = { NSApp.terminate(nil) }

    init(
        instanceLease: SingleInstanceLease? = nil,
        wakeNotifications: NotificationCenterClient = DistributedNotificationCenterAdapter()
    ) {
        self.instanceLease = instanceLease
        self.wakeNotifications = wakeNotifications
        super.init()
        wakeObserver = wakeNotifications.addObserver(forName: .inputLockWakeExistingInstance) { [weak self] in
            MainActor.assumeIsolated {
                self?.handleInstanceWake()
            }
        }
    }

    /// 主菜单截图入口最近一次可见失败（manager 未安装等）；供诊断与测试观察。
    private(set) var lastScreenshotMenuError: String?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 异步编排：恢复 → bootstrap → UI
        Task { @MainActor in
            let root = await AppCompositionRoot.composeAfterClamshellRecovery()
            self.compositionRoot = root

            MainMenuInstaller.install(target: self, strings: root.appState.l10n.s)
            self.setupSettingsManager()
            self.setupPermissionSubscriptions()
            // 自动更新：应用就绪后再确认启动 updater（LSUIElement 菜单栏应用，周期检查延迟于启动）。
            UpdateManager.shared.start()

            let coordinator = OnboardingCoordinator.shared
            coordinator.onCompletionAnchoring = { [weak root] in
                root?.statusBarController.openPanel()
            }
            coordinator.onApplyDockIconPreference = { [weak root] retainDock in
                root?.appState.setHideDockIcon(!retainDock)
            }
            coordinator.onApplyLaunchAtLogin = { [weak root] enabled in
                _ = root?.appState.launchAtLogin.setEnabled(enabled)
            }
            OnboardingWindowController.shared.startObserving(coordinator, l10n: root.appState.l10n, appearance: root.appState.appearance)
            DispatchQueue.main.async {
                coordinator.startIfNeeded()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 清理已成功完成：本次终止直接放行。
        if hasCompletedTerminationCleanup {
            return .terminateNow
        }
        // 清理进行中（重复 Quit）：本次终止取消，等清理完成后的重试。
        if isTerminating {
            return .terminateCancel
        }
        isTerminating = true

        if terminationTask == nil {
            // 不能返回 .terminateLater 后再等 Task：AppKit 会在 `_shouldTerminate`
            // 内进入等待 reply 的嵌套 runloop，MainActor 任务在该循环中不会被调度，
            // reply 永不触发 → 应用卡在「终止中」，主线程被嵌套 runloop 占住，
            // 整个 UI 无响应（2026-10-25 实测点面板「退出」后必现）。
            // 改为 cancel-then-retry：先取消本次终止回到正常 runloop，清理完成后
            // 再次 terminate，由上面的标志直接放行。清理失败则保持运行，可重试。
            terminationTask = Task { @MainActor in
                let ok = await self.runTerminationCleanup()
                self.terminationTask = nil
                self.isTerminating = false
                if ok {
                    self.hasCompletedTerminationCleanup = true
                    self.terminateAction()
                }
                return ok
            }
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let root = compositionRoot else { return }
        // 不重复清理已由 shutdown 处理的资源；只停剪贴板等无关 keep-awake 的监听。
        root.appState.clipboardHistory?.stopMonitoring()
        root.appState.clipboardHotkey?.stopListening()
    }

    /// 单一退出清理入口（可测）。
    func runTerminationCleanup() async -> Bool {
        guard let root = compositionRoot else { return true }
        return await root.prepareForApplicationTermination()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 菜单栏图标丢失时的恢复入口。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        openSettings()
        return true
    }

    // MARK: - Settings

    @objc func openSettings() {
        openSettings(tab: nil)
    }

    func openSettings(tab: SettingsToolbarTab?) {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowManager?.showSettings(tab: tab)
    }

    @objc func openShelf() {
        FeatureRuntime.shared.manager(for: .shelf, as: ShelfService.self)?.summon()
    }

    @objc func checkForUpdates() {
        // LSUIElement 应用：先激活，避免 Sparkle 更新窗口在后台弹出被忽略。
        NSApp.activate(ignoringOtherApps: true)
        UpdateManager.shared.checkForUpdates()
    }

    // MARK: - Screenshot 主菜单入口

    @objc func captureScreenshotAllInOne() {
        guard let manager = FeatureRuntime.shared.manager(
            for: .screenshot,
            as: ScreenshotFeatureManager.self
        ) else {
            let reason = (
                compositionRoot?.appState.l10n.s ?? L10n().s
            ).screenshotHotkeyIgnoredUnavailable
            lastScreenshotMenuError = reason
            Self.logger.error(
                "screenshot menu allInOne denied (manager missing): \(reason, privacy: .public)"
            )
            NSSound.beep()
            return
        }
        lastScreenshotMenuError = nil
        manager.handleAllInOne()
    }

    @objc func captureScreenshotFullscreen() {
        guard let manager = FeatureRuntime.shared.manager(
            for: .screenshot,
            as: ScreenshotFeatureManager.self
        ) else {
            let reason = (
                compositionRoot?.appState.l10n.s ?? L10n().s
            ).screenshotHotkeyIgnoredUnavailable
            lastScreenshotMenuError = reason
            Self.logger.error(
                "screenshot menu fullscreen denied (manager missing): \(reason, privacy: .public)"
            )
            NSSound.beep()
            return
        }
        lastScreenshotMenuError = nil
        manager.handleHotkey(mode: .fullScreen, intent: .copy)
    }

    /// 退出并重新打开 app。完全磁盘访问只对新进程生效。
    func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.3; /usr/bin/open \"$1\"", "omniforge-relaunch", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// 仅供测试：手动设置 settingsWindowManager
    func setupSettingsManager() {
        if settingsWindowManager == nil, let root = compositionRoot {
            settingsWindowManager = SettingsWindowManager(appState: root.appState)
        }
        if pendingSettingsWake, settingsWindowManager != nil {
            pendingSettingsWake = false
            openSettings()
        }
    }

    private func handleInstanceWake() {
        guard settingsWindowManager != nil else {
            pendingSettingsWake = true
            return
        }
        openSettings()
    }

    // MARK: - 权限订阅

    func setupPermissionSubscriptions() {
        // inputMonitoring 无订阅：当前无特性在 possiblePermissions 中声明它，
        // sync 的特性列表恒为空；未来有特性声明时再补对称订阅。
        Permissions.shared.$accessibility
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let features = AppFeature.allCases.filter {
                    $0.permissions.contains(.accessibility)
                }
                FeatureRuntime.shared.sync(features)
            }
            .store(in: &cancellables)

        Permissions.shared.$screenRecording
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let features = AppFeature.allCases.filter {
                    $0.permissions.contains(.screenRecording)
                }
                FeatureRuntime.shared.sync(features)
            }
            .store(in: &cancellables)
    }
}
