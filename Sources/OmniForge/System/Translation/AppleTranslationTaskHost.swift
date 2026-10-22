import SwiftUI
import Translation

/// 系统翻译任务宿主：挂在浮窗视图树中，负责取得 `TranslationSession` 并驱动 bridge。
///
/// macOS 15 不提供可直接构造的 `TranslationSession`，`.translationTask` 是唯一能取得
/// 系统会话的入口；因此视图与 bridge 分成两个文件（bridge 只需 Combine + Translation）。
/// 视图消失时必须通过 `hostDidDisappear()` 结束等待，不能依赖窗口收起后一定销毁 SwiftUI 树。
@available(macOS 15.0, *)
@MainActor
struct AppleTranslationTaskHost: View {
    @ObservedObject var bridge: AppleTranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(bridge.configuration) { session in
                // SwiftUI 在配置变化时创建新会话；会话只在任务闭包内使用，
                // 纯值结果通过 bridge 的完成入口回交主 actor。
                await bridge.runSession(SystemTranslationSessionDriver(session: session))
            }
            .onAppear { bridge.hostDidAppear() }
            .onDisappear { bridge.hostDidDisappear() }
    }
}
