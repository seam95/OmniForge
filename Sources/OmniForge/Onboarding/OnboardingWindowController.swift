import AppKit
import Combine
import SwiftUI

/// Onboarding 窗口管理器 — 创建并管理独立的 NSWindow，
/// 监听 OnboardingCoordinator 的状态变化自动显示/关闭窗口。
/// 同时担任窗口 delegate：用户经标题栏红钮（而非应用内按钮）关闭时，
/// 同步 coordinator 状态，避免 `isWindowVisible` 残留 true 导致
/// 「重新运行引导」失灵、What's New 每次启动重弹。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var onboardingWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var l10n: L10n?
    private weak var appearance: AppearanceSettings?

    private override init() {
        super.init()
    }

    /// 开始监听 coordinator 状态，自动管理窗口
    func startObserving(_ coordinator: OnboardingCoordinator, l10n: L10n, appearance: AppearanceSettings) {
        self.l10n = l10n
        self.appearance = appearance
        subscriptions.removeAll()

        coordinator.$isWindowVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible {
                    self?.showOnboardingWindow(coordinator: coordinator)
                } else {
                    self?.closeOnboardingWindow()
                }
            }
            .store(in: &subscriptions)

        coordinator.$isWhatsNewVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible {
                    self?.showWhatsNewWindow(coordinator: coordinator)
                } else {
                    self?.closeWhatsNewWindow()
                }
            }
            .store(in: &subscriptions)
    }

    private func showOnboardingWindow(coordinator: OnboardingCoordinator) {
        guard onboardingWindow == nil else { return }
        guard let l10n else { return }

        let view = OnboardingView(coordinator: coordinator, l10n: l10n)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false

        onboardingWindow = window
        window.delegate = self
        appearance?.attach(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 红钮关闭：先置空引用（阻断 sink 回调的递归），再同步 coordinator 状态。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            onboardingWindow = nil
            if OnboardingCoordinator.shared.isWindowVisible {
                OnboardingCoordinator.shared.isWindowVisible = false
            }
        } else if window === whatsNewWindow {
            whatsNewWindow = nil
            OnboardingCoordinator.shared.skipWhatsNew()
        }
    }

    private func closeOnboardingWindow() {
        guard let window = onboardingWindow else { return }
        window.orderOut(nil)
        window.close()
        onboardingWindow = nil
    }

    private func showWhatsNewWindow(coordinator: OnboardingCoordinator) {
        guard whatsNewWindow == nil else { return }
        guard let l10n else { return }

        let view = WhatsNewView(
            strings: l10n.s,
            lastSeenVersion: coordinator.lastSeenVersion,
            onClose: { [weak coordinator] in coordinator?.skipWhatsNew() }
        )
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = l10n.s.whatsNewTitle
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false

        whatsNewWindow = window
        window.delegate = self
        appearance?.attach(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWhatsNewWindow() {
        whatsNewWindow?.orderOut(nil)
        whatsNewWindow = nil
    }

    func closeAllWindows() {
        closeOnboardingWindow()
        closeWhatsNewWindow()
    }
}
