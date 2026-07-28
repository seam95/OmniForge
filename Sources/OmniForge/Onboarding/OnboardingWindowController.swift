import AppKit
import Combine
import SwiftUI

/// Onboarding 窗口管理器 — 创建并管理独立的 NSWindow，
/// 监听 OnboardingCoordinator 的状态变化自动显示/关闭窗口。
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var onboardingWindow: NSWindow?
    private var whatsNewWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var l10n: L10n?

    private init() {}

    /// 开始监听 coordinator 状态，自动管理窗口
    func startObserving(_ coordinator: OnboardingCoordinator, l10n: L10n) {
        self.l10n = l10n
        subscriptions.removeAll()

        coordinator.$isWindowVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
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
            .receive(on: DispatchQueue.main)
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
    }

    private func showWhatsNewWindow(coordinator: OnboardingCoordinator) {
        guard whatsNewWindow == nil else { return }
        guard let l10n else { return }

        let view = WhatsNewView(
            strings: l10n.s,
            onClose: { [weak coordinator] in coordinator?.skipWhatsNew() }
        )
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = l10n.s.whatsNewTitle
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false

        whatsNewWindow = window
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
