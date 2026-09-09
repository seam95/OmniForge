import AppKit
import Foundation

/// 提示词优化 HUD 边界（决策 D8：屏幕底部居中，复用 `EditorInfoToastWindow`）。
/// 状态流转：`showRunning` 常驻 → `showOutcome` 同窗更新为结果文案并按成功/失败各自停留。
@MainActor
protocol PromptOptimizerHUDPresenting: AnyObject {
    /// 「优化中…」常驻展示，直到 outcome 或 dismiss。
    func showRunning(_ text: String)
    /// 结果态：成功停 ~2s、失败停 ~2.5s（决策 D7）。
    func showOutcome(_ text: String, isFailure: Bool)
}

/// 基于 `EditorInfoToastWindow` 的实现：同一窗口承载 running → outcome 流转，不重建窗口。
@MainActor
final class EditorToastPromptOptimizerHUD: PromptOptimizerHUDPresenting {
    private let toast: EditorInfoToastWindow

    init(toast: EditorInfoToastWindow = EditorInfoToastWindow()) {
        self.toast = toast
    }

    func showRunning(_ text: String) {
        // duration <= 0：常驻，不排自动消失。
        toast.present(text, duration: 0)
    }

    func showOutcome(_ text: String, isFailure: Bool) {
        toast.update(text, duration: isFailure ? 2.5 : 2.0)
    }
}
