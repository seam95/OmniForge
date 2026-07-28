import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import UserNotifications

/// 「获取权限」按钮对应的动作类型。
enum PermissionGrantAction: Equatable {
    case promptAccessibility
    case openInputMonitoringSettings
    case requestNotifications
    case requestFullDiskAccess
    case requestScreenRecording
}

/// 集中式权限管理 — 监听 Accessibility 和 Input Monitoring 状态变化，
/// 变化时通过 @Published 通知观察者；FeatureRuntime.sync 消费这些变化。
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var fullDiskAccess = false
    @Published private(set) var signatureSummary = PermissionSignatureSummary(
        kind: .unsigned,
        identifier: "unknown"
    )
    @Published private(set) var screenRecording = false

    /// notifications 权限检查需要异步调用 UNUserNotificationCenter，
    /// 当前阶段仅声明占位，后续 Task 接入实际检查。
    @Published private(set) var notifications = false

    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private let probe: PermissionProbing

    init(
        probe: PermissionProbing = SystemPermissionProbe(),
        observeActivation: Bool = true
    ) {
        self.probe = probe
        refresh()
        if observeActivation {
            observeAppActivation()
        }
    }

    /// 重新检查所有权限状态
    func refresh() {
        accessibility = probe.accessibilityGranted
        inputMonitoring = probe.inputMonitoringGranted
        screenRecording = probe.screenRecordingGranted
        signatureSummary = probe.signatureSummary
        checkFullDiskAccess()
        checkNotifications()
    }

    // MARK: - 统一请求入口

    /// 未授予时点击「获取权限」应执行的动作（纯映射，无状态）。
    nonisolated static func grantAction(for permission: AppPermission) -> PermissionGrantAction {
        switch permission {
        case .accessibility: return .promptAccessibility
        case .inputMonitoring: return .openInputMonitoringSettings
        case .notifications: return .requestNotifications
        case .fullDiskAccess: return .requestFullDiskAccess
        case .screenRecording: return .requestScreenRecording
        }
    }

    /// 按权限类型发起请求或打开对应系统设置页。
    func requestAccess(for permission: AppPermission) {
        switch Self.grantAction(for: permission) {
        case .promptAccessibility:
            requestAccessibility()
        case .openInputMonitoringSettings:
            openInputMonitoringSettings()
        case .requestNotifications:
            requestNotifications()
        case .requestFullDiskAccess:
            requestFullDiskAccess()
        case .requestScreenRecording:
            _ = requestScreenRecordingAccess()
        }
    }

    /// 请求辅助功能权限（系统弹窗；若此前已拒绝则仅打开设置页）。
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibility = trusted || AXIsProcessTrusted()
        if !accessibility {
            openAccessibilitySettings()
        }
        return accessibility
    }

    func openAccessibilitySettings() {
        openPrivacySettings(pane: "Privacy_Accessibility")
    }

    /// 输入监控无可靠 prompt API，直接打开系统设置对应页。
    func openInputMonitoringSettings() {
        openPrivacySettings(pane: "Privacy_ListenEvent")
    }

    func requestNotifications() {
        // 与 checkNotifications 一致：非 .app 宿主调用会崩溃。
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    // MARK: - 权限检查

    // MARK: - 屏幕录制（屏幕截图功能；preflight 走 probe，请求/打开设置在此）

    /// 请求屏幕录制权限。授权结果变化依赖应用激活时的 refresh。
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        screenRecording = granted || CGPreflightScreenCaptureAccess()
        return screenRecording
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(pane: "Privacy_ScreenCapture")
    }

    private func openPrivacySettings(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    private func checkNotifications() {
        // SPM / XCTest 宿主不是 .app 时，UNUserNotificationCenter.current() 会因
        // bundleProxyForCurrentProcess 为空而崩溃；仅在真实 app bundle 中查询。
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                self?.notifications = granted
            }
        }
    }

    // MARK: - 完全磁盘访问（FDA）

    /// 无提示地检测完全磁盘访问。读取 TCC 数据库是经典信号，但该文件在某些 macOS 版本上不存在
    /// （因此缺失文件会永远读作"无访问"，即便已授予）。可靠的回退是列出一个存在的受保护目录：
    /// 无 FDA 时该列出被拒绝，有 FDA 时成功。
    private func checkFullDiskAccess() {
        // 涉及阻塞文件 IO，放到后台线程，避免卡主线程；状态更新回主线程。
        DispatchQueue.global(qos: .utility).async {
            let granted = Self.probeFullDiskAccess()
            Task { @MainActor in
                if self.fullDiskAccess != granted { self.fullDiskAccess = granted }
            }
        }
    }

    nonisolated private static func probeFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // 存在时优先：TCC 数据库仅在有访问权限时可读。
        let tccDB = (home as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = FileHandle(forReadingAtPath: tccDB) {
            let ok = (try? handle.read(upToCount: 1)) != nil
            try? handle.close()
            if ok { return true }
        }

        // 每个版本都有效：以下目录均由 FDA 门控，成功列出（即便是空目录）意味着已授予。
        let gatedDirs = [
            "Library/Safari",
            "Library/Mail",
            "Library/Messages",
            "Library/Cookies",
            "Library/Suggestions",
            "Library/Application Support/MobileSync",
        ].map { (home as NSString).appendingPathComponent($0) }
        return gatedDirs.contains { (try? fm.contentsOfDirectory(atPath: $0)) != nil }
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// FDA 无提示 API，且 app 只有在尝试读取受保护位置后才在其系统设置列表中出现（默认关闭）。
    /// 触发可能的受保护路径以注册 app，然后短暂延迟打开面板，让 tccd 在系统设置读取列表前记录拒绝。
    /// 若仍未出现，用户可用列表的 + 按钮添加。
    func requestFullDiskAccess() {
        DispatchQueue.global(qos: .userInitiated).async {
            let home = NSHomeDirectory()
            let fm = FileManager.default
            // TCC 数据库存在时是经典触发器。某些 macOS 版本省略它，因此下面的受保护目录是回退注册尝试。
            let tccDB = (home as NSString)
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
            _ = try? Data(contentsOf: URL(fileURLWithPath: tccDB), options: .mappedIfSafe)
            if let handle = FileHandle(forReadingAtPath: tccDB) {
                _ = try? handle.read(upToCount: 1)
                try? handle.close()
            }
            // 几个受保护位置，缺失时无害。
            let dirs = [
                "Library/Application Support/com.apple.TCC",
                "Library/Safari",
                "Library/Mail",
                "Library/Messages",
                "Library/Cookies",
                "Library/Application Support/MobileSync",
            ].map { (home as NSString).appendingPathComponent($0) }
            for path in dirs { _ = try? fm.contentsOfDirectory(atPath: path) }

            // 让 tccd 在面板加载列表前持久化拒绝。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.openFullDiskAccessSettings()
            }
        }
    }

    // MARK: - 应用激活/失活监听

    private func observeAppActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - 测试支持

    func resetForTesting() {
        accessibility = false
        inputMonitoring = false
        fullDiskAccess = false
        notifications = false
        signatureSummary = PermissionSignatureSummary(kind: .unsigned, identifier: "unknown")
        screenRecording = false
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }

    /// 仅供测试：直接设置 accessibility 状态
    func setAccessibilityForTesting(_ value: Bool) {
        accessibility = value
    }

    /// 仅供测试：直接设置 fullDiskAccess 状态
    func setFullDiskAccessForTesting(_ value: Bool) {
        fullDiskAccess = value
    }

    /// 仅供测试：直接设置 screenRecording 状态
    func setScreenRecordingForTesting(_ value: Bool) {
        screenRecording = value
    }
}
