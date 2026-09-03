import SwiftUI

/// 页面级转场规范：与 `Theme.Animation.pageTransition` 配套。
///
/// 平级切换（tab / 控制中心面板）用淡入淡出 + 轻微纵向位移；
/// 层级切换（列表 → 详情）用侧滑推入，进入方向由调用方传入。
enum PageTransition {
    /// 平级切换：淡入淡出 + 自下方轻浮入，位移刻意很小以避免与 popover 高度过渡打架。
    static let peer = AnyTransition.opacity.combined(with: .offset(y: 6))

    /// 层级推入：`from` 为新页面进入方向（前进传 `.trailing`，根页面传 `.leading`）。
    static func push(from edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }
}

extension View {
    /// 平级面板切换转场。分支内容须置于 ZStack 内，动画由容器上的
    /// `.animation(Theme.Animation.pageTransition, value:)` 或 `withAnimation` 驱动。
    func peerTransition() -> some View {
        transition(PageTransition.peer)
    }

    /// 层级推入转场：`from` 为该页面的进入方向。
    func pushTransition(from edge: Edge) -> some View {
        transition(PageTransition.push(from: edge))
    }
}
