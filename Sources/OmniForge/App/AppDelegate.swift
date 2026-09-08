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
    private var isTerminating = false

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

            let coordinator = OnboardingCoordinator.shared
            OnboardingWindowController.shared.startObserving(coordinator, l10n: root.appState.l10n)
            DispatchQueue.main.async {
                coordinator.startIfNeeded()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            // 已在事务中：继续等待，不启动第二个事务。
            return .terminateLater
        }
        isTerminating = true

        if terminationTask == nil {
            terminationTask = Task { @MainActor in
                let ok = await self.runTerminationCleanup()
                if ok {
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    self.isTerminating = false
                    self.terminationTask = nil
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                return ok
            }
        }
        return .terminateLater
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
