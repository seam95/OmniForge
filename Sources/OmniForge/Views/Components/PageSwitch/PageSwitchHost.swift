import SwiftUI

/// SPEC §8.2 页面表面样式：由 Host 统一持有，页面内容根视图不得再自铺背景。
struct PageSurface: Equatable {
    /// 页面背景色；nil = 透明（沿用壳层默认底）。
    var background: Color?

    static let clear = PageSurface()
}

/// 转场阶段事件：仅供观测（signpost / 测试 / 页脚联动），不是控制流。
enum PageSwitchPhaseEvent: Equatable {
    case exitStarted
    case routeSwapped
    case enterCompleted
}

/// SPEC §6.1 Page Switch 深模块宿主：单活动树、分阶段淡出后淡入。
///
/// 调用方只提供：请求 route、(旧, 新) → 切换语义、route → 表面样式、
/// 内容构造闭包。阶段推进、latest-wins 合并、动画参数、Reduce Motion
/// 降级、背景切换时机、内容区 hit-testing 门控均为模块内部实现。
///
/// 单活动树不变量（SPEC §6.3）：`body` 中内容仅有一个构造调用点，只消费
/// `displayedRoute`；route 替换发生在禁用动画的 `Transaction` 中；不使用
/// 双分支 ZStack 叠放，也不依赖 `.id(selection)` 强制重建。
///
/// 阶段时钟：退出/进入的完成由显式 `Task.sleep`（等于动效时长）驱动，
/// 不依赖 SwiftUI 动画 completion —— 离屏/测试环境同样确定性推进；
/// 视觉插值仍由 `withAnimation` 承担。宿主销毁时在途转场收敛到最后
/// 请求 route（SPEC §14.2）。
struct PageSwitchHost<Route: Equatable, Content: View>: View {
    let requestedRoute: Route
    let semantics: (_ from: Route, _ to: Route) -> PageSwitchSemantics
    let surface: (Route) -> PageSurface
    /// Reduce Motion 注入口：nil 读系统设置；测试与预览可显式指定。
    var reduceMotionOverride: Bool? = nil
    /// 内容树挂载计数观测（测试配置用；+1 onAppear / -1 onDisappear）。
    var contentMountObserver: (@MainActor (Int) -> Void)? = nil
    var onPhaseEvent: (@MainActor (PageSwitchPhaseEvent) -> Void)? = nil
    var onDisplayedSurfaceChange: (@MainActor (Route, PageSurface) -> Void)? = nil
    @ViewBuilder let content: (Route) -> Content

    enum VisualState {
        /// 稳定：opacity 1，无位移。
        case settled
        /// 退出终点：opacity 0，位于退出位移处。
        case exited
        /// 进入起点：opacity 0，位于进入位移处。
        case enteringStart
    }

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    @State private var machine: PageSwitchStateMachine<Route>
    @State private var visual: VisualState = .settled
    @State private var displayedSurface: PageSurface
    @State private var transitionMotion: PageSwitchMotion?
    @State private var transitionTask: Task<Void, Never>?

    init(
        requestedRoute: Route,
        semantics: @escaping (_ from: Route, _ to: Route) -> PageSwitchSemantics,
        surface: @escaping (Route) -> PageSurface,
        reduceMotionOverride: Bool? = nil,
        contentMountObserver: (@MainActor (Int) -> Void)? = nil,
        onPhaseEvent: (@MainActor (PageSwitchPhaseEvent) -> Void)? = nil,
        onDisplayedSurfaceChange: (@MainActor (Route, PageSurface) -> Void)? = nil,
        @ViewBuilder content: @escaping (Route) -> Content
    ) {
        self.requestedRoute = requestedRoute
        self.semantics = semantics
        self.surface = surface
        self.reduceMotionOverride = reduceMotionOverride
        self.contentMountObserver = contentMountObserver
        self.onPhaseEvent = onPhaseEvent
        self.onDisplayedSurfaceChange = onDisplayedSurfaceChange
        self.content = content
        _machine = State(initialValue: PageSwitchStateMachine(initial: requestedRoute))
        _displayedSurface = State(initialValue: surface(requestedRoute))
    }

    var body: some View {
        ZStack {
            content(machine.displayedRoute)
                .opacity(visual == .settled ? 1 : 0)
                .offset(x: visualOffset)
                // SPEC §11.1：转场期间内容区禁用 hit-testing，导航区继续接受最新请求。
                .allowsHitTesting(machine.phase.isIdle)
                .onAppear { contentMountObserver?(1) }
                .onDisappear { contentMountObserver?(-1) }
        }
        .background(displayedSurface.background)
        .onAppear {
            onDisplayedSurfaceChange?(machine.displayedRoute, displayedSurface)
        }
        .onChange(of: requestedRoute) { _, newRoute in
            request(newRoute)
        }
        .onDisappear {
            // 宿主销毁：丢弃在途转场时钟，状态机收敛到最后请求 route。
            transitionTask?.cancel()
            transitionTask = nil
            machine.handle(.cancel)
        }
    }

    // MARK: - 转场编排

    private func request(_ route: Route) {
        let before = machine.phase
        machine.handle(.request(route))
        guard machine.phase != before else { return }
        guard case .exiting = machine.phase else { return }
        // 已在 exiting 中（仅替换 pending）：不重启退出动画（SPEC §6.2）。
        if case .exiting = before { return }
        startExit()
    }

    private func startExit() {
        guard case .exiting(let displayed, let pending) = machine.phase else { return }
        let motion = PageSwitchMotion.resolved(
            semantics: semantics(displayed, pending),
            reduceMotion: effectiveReduceMotion
        )
        transitionMotion = motion
        onPhaseEvent?(.exitStarted)
        withAnimation(motion.exitAnimation) {
            visual = .exited
        }
        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(motion.exitDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            swapRoute()
        }
    }

    private func swapRoute() {
        guard case .exiting(let displayed, let pending) = machine.phase else { return }
        let motion = PageSwitchMotion.resolved(
            semantics: semantics(displayed, pending),
            reduceMotion: effectiveReduceMotion
        )
        transitionMotion = motion

        // SPEC §6.3.2：route 替换与表面更新在禁用动画的 Transaction 中执行。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            machine.handle(.exitCompleted)
            displayedSurface = surface(pending)
            visual = .enteringStart
        }
        onPhaseEvent?(.routeSwapped)
        onDisplayedSurfaceChange?(pending, displayedSurface)
        PageSwitchSignpost.emit(PageSwitchSignpost.Event.routeSwapped)

        withAnimation(motion.enterAnimation) {
            visual = .settled
        }
        transitionTask?.cancel()
        transitionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(motion.enterDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finishEnter()
        }
    }

    private func finishEnter() {
        machine.handle(.enterCompleted)
        visual = .settled
        onPhaseEvent?(.enterCompleted)
        PageSwitchSignpost.emit(PageSwitchSignpost.Event.enterCompleted)
        // entering 期间排队的下一目标：立即开始下一轮退出。
        if case .exiting = machine.phase {
            startExit()
        }
    }

    private var visualOffset: CGFloat {
        switch visual {
        case .settled: 0
        case .exited: transitionMotion?.exitOffsetX ?? 0
        case .enteringStart: transitionMotion?.enterStartOffsetX ?? 0
        }
    }
}
