import Foundation
import AppKit
import SwiftUI

@MainActor
final class CleaningOverlayViewModel: ObservableObject {
    @Published var style: CleaningOverlayStyle = .black
    @Published var holdProgress: Double?
    @Published var isHintVisible = true
    /// 提示文案按模式注入：屏幕清洁与键盘清洁文案不同。
    @Published var hintText = ""
    /// false = 键盘清洁提示窗模式：无纯色底，仅中央提示。
    @Published var showsSolidBackground = true
}

/// 屏幕清洁遮罩控制器：每屏一个置顶 NSPanel（对齐截图遮罩范式，SPEC D9 全屏覆盖）。
@MainActor
final class CleaningOverlayWindowController: CleaningOverlayPresenting {
    private let stringsProvider: () -> Strings
    private let model = CleaningOverlayViewModel()
    private var panels: [NSPanel] = []
    private var hintTask: Task<Void, Never>?

    /// 屏幕清洁提示文案展示时长（秒），之后淡出保持遮罩纯净（SPEC D8）；键盘清洁提示常驻。
    private let hintDuration: TimeInterval = 5

    init(stringsProvider: @escaping () -> Strings) {
        self.stringsProvider = stringsProvider
    }

    // MARK: - CleaningOverlayPresenting

    func present(style: CleaningOverlayStyle) {
        if panels.isEmpty {
            model.style = style
            model.holdProgress = nil
            model.isHintVisible = true
            model.hintText = stringsProvider().cleaningModeScreenLockedHint
            model.showsSolidBackground = true
            for screen in NSScreen.screens {
                let panel = makePanel(for: screen, solidBackground: true)
                panels.append(panel)
                panel.orderFrontRegardless()
            }
            NSCursor.hide()
            scheduleHintFadeOut()
        } else {
            // 运行中换肤：仅更新底色，不重建面板。
            model.style = style
        }
    }

    func presentHint() {
        guard panels.isEmpty else { return }
        model.holdProgress = nil
        model.isHintVisible = true
        model.hintText = stringsProvider().cleaningModeLockedHint
        model.showsSolidBackground = false
        for screen in NSScreen.screens {
            let panel = makePanel(for: screen, solidBackground: false)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        // 键盘清洁提示常驻整个会话：淡出后用户将无从知晓锁定状态与退出方式。
    }

    func dismiss() {
        hintTask?.cancel()
        hintTask = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        model.holdProgress = nil
        NSCursor.unhide()
    }

    func setHoldProgress(_ progress: Double?) {
        model.holdProgress = progress
    }

    // MARK: - 私有

    private func makePanel(for screen: NSScreen, solidBackground: Bool) -> NSPanel {
        let frame = screen.frame
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 提示窗不参与交互也不挡视线；遮罩窗吞住事件（拦截层兜底）。
        panel.ignoresMouseEvents = !solidBackground
        panel.setFrame(frame, display: false)
        panel.contentView = NSHostingView(
            rootView: CleaningOverlayView(model: model)
        )
        return panel
    }

    private func scheduleHintFadeOut() {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.hintDuration ?? 5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.model.isHintVisible = false
        }
    }
}
