import Foundation

/// SPEC §6.2 页面切换状态机：纯内存、确定性、latest-wins。
///
/// 阶段推进由宿主的显式时钟驱动（`exitCompleted` / `mountCompleted` /
/// `enterCompleted`），不依赖 SwiftUI 动画回调；动画丢失或取消时调用方发
/// `cancel` 强制收敛到最后请求 route 的 `idle`（SPEC §14.2）。
///
/// `mounting` 相位承载控制中心自适应尺寸规格的 preparing/resizing 透明
/// 阶段：route 已挂载但保持透明，等待测量与壳层改高完成（§4.1）。
/// 不接尺寸屏障的宿主在挂载后立即发 `mountCompleted`，行为与固定尺寸
/// 时代一致。
struct PageSwitchStateMachine<Route: Equatable>: Equatable {
    enum Phase: Equatable {
        /// 当前页面稳定展示，可交互。
        case idle(displayed: Route)
        /// 旧页面退出中；`pending` 为最后请求目标（latest-wins）。
        case exiting(displayed: Route, pending: Route)
        /// 新页面已挂载且保持透明；等待测量/改高屏障。
        /// 挂载目标尚未展示，期间收到的新请求直接透明替换 `displayed`
        ///（SPEC §6.2，不必先淡入），因此 `pending` 恒为 nil。
        case mounting(displayed: Route)
        /// 新页面已进入；期间收到的请求记为下一目标。
        case entering(displayed: Route, pending: Route?)

        var displayedRoute: Route {
            switch self {
            case .idle(let displayed), .exiting(let displayed, _),
                 .mounting(let displayed), .entering(let displayed, _):
                return displayed
            }
        }

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }
    }

    enum Event {
        case request(Route)
        /// 旧页淡出完成：route 无动画替换为最后 pending，进入透明 mounting。
        case exitCompleted
        /// 挂载屏障（测量/改高）完成，开始淡入。
        case mountCompleted
        case enterCompleted
        /// 动画回调丢失/宿主销毁时强制收敛到最后请求 route。
        case cancel
    }

    private(set) var phase: Phase

    init(initial: Route) {
        phase = .idle(displayed: initial)
    }

    /// 当前展示 route（exiting 期间保持旧值，交换点无动画替换）。
    var displayedRoute: Route {
        phase.displayedRoute
    }

    mutating func handle(_ event: Event) {
        switch event {
        case .request(let route):
            handleRequest(route)
        case .exitCompleted:
            // 防重入：仅在 exiting 中生效；displayed 无动画替换为最后 pending。
            guard case .exiting(_, let pending) = phase else { return }
            phase = .mounting(displayed: pending)
        case .mountCompleted:
            guard case .mounting(let displayed) = phase else { return }
            phase = .entering(displayed: displayed, pending: nil)
        case .enterCompleted:
            guard case .entering(let displayed, let pending) = phase else { return }
            guard let pending, pending != displayed else {
                phase = .idle(displayed: displayed)
                return
            }
            phase = .exiting(displayed: displayed, pending: pending)
        case .cancel:
            switch phase {
            case .idle:
                break
            case .exiting(_, let pending):
                phase = .idle(displayed: pending)
            case .mounting(let displayed):
                phase = .idle(displayed: displayed)
            case .entering(let displayed, let pending):
                phase = .idle(displayed: pending ?? displayed)
            }
        }
    }

    private mutating func handleRequest(_ route: Route) {
        switch phase {
        case .idle(let displayed):
            // 请求当前 route：忽略，不启动动画（SPEC §6.2）。
            guard route != displayed else { return }
            phase = .exiting(displayed: displayed, pending: route)
        case .exiting(let displayed, _):
            // 再次请求只替换 pending，不新增动画（latest-wins）。
            phase = .exiting(displayed: displayed, pending: route)
        case .mounting(let displayed):
            if route == displayed { return }
            // 挂载目标尚未展示：透明阶段直接替换（SPEC §6.2，不必先淡入）。
            phase = .mounting(displayed: route)
        case .entering(let displayed, let pending):
            // 请求正在进入的 route 且无排队：忽略；否则记为下一目标，不中断当前淡入。
            if route == displayed && pending == nil { return }
            phase = .entering(displayed: displayed, pending: route)
        }
    }
}
