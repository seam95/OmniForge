import AppKit
import SwiftUI

/// 设置窗口管理器 — 用 NSWindow + NSHostingController 替代 SwiftUI Settings scene。
/// 支持窗口复用（单例窗口）、尺寸记忆、最小尺寸约束。
@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let appState: AppState
    let navigation = SettingsNavigationModel()

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// 显示设置窗口。首次调用时创建窗口，后续调用复用并前置。
    /// - Parameter tab: 可选目标页；不可见时回退到第一个可见 tab。
    func showSettings(tab: SettingsToolbarTab? = nil) {
        if let tab {
            navigation.select(tab, isAvailable: FeatureRuntime.shared.isAvailable)
        }
        if window == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(state: appState, navigation: navigation)
            )
            let newWindow = NSWindow(contentViewController: hostingController)
            // .miniaturizable 让窗口菜单的 Cmd+M 最小化生效
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.title = appState.l10n.s.settingsTitle
            newWindow.setContentSize(NSSize(width: 820, height: 560))
            newWindow.minSize = NSSize(width: 760, height: 480)
            newWindow.isReleasedWhenClosed = false
            newWindow.isRestorable = false
            newWindow.hidesOnDeactivate = false
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
            // 设置窗口在外观白名单：偏好切换即时生效。
            appState.appearance.attach(newWindow)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 关闭设置窗口并释放引用，避免设置页视图树长期驻留。
    func closeSettings() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        closingWindow.delegate = nil
        window = nil
    }
}
