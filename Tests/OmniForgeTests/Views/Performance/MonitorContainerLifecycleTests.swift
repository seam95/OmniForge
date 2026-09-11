import XCTest
import SwiftUI
@testable import OmniForge

/// 监控容器视图生命周期回归：内容树重建（onDisappear 后）进程展开回调必须仍可达。
///
/// 背景缺陷（2026-09-05 真机日志实锤）：自适应高度等流程会在面板打开期重建
/// 内容树，新实例 onAppear 先绑定、旧实例 onDisappear 后执行时曾把 onToggle
/// 解绑清空，导致排行页点击展开请求永久丢失、processState 停在 collapsed，
/// 页面永卡「加载 X 占用」。修复 = onDisappear 只 close 不解绑。
///
/// 重建用 `.id()` 走 SwiftUI 原生生命周期（同生产中内容树重建路径），
/// 不直接销毁 NSHostingView——后者会与在途渲染任务竞态崩溃（已实测）。
@MainActor
final class MonitorContainerLifecycleTests: XCTestCase {

    /// 挂载真实 MonitorContainerView → 内容树重建 → 展开回调仍可达。
    func test_onDisappearKeepsToggleReachableAfterContentTreeRebuild() async throws {
        let state = LifecycleHarnessState()
        let window = try mountLifecycleHarness(state)

        // 1) 视图 onAppear 完成 onToggle 绑定（真实链路：视图内绑定）
        try await waitFor { state.coordinator.onToggle != nil }
        XCTAssertTrue(state.coordinator.onToggle != nil, "挂载后 onToggle 应已绑定")

        // 2) 模拟点击 CPU 卡片（onSelectRankable 闭包内容）：open + 路由切换
        state.coordinator.open(.cpu)
        state.route = .ranking(.cpu)
        try await waitFor { state.received.last == .cpu }
        XCTAssertEqual(state.received.last, .cpu, "挂载期展开请求应到达宿主接线")
        // 等转场收敛，避免重建与在途转场交叉
        try await Task.sleep(nanoseconds: 500_000_000)

        // 3) 内容树重建（自适应高度流程同款路径）：旧树 onDisappear 只 close
        state.rebuildToken += 1
        // 收到 nil（close 折叠）即旧树已卸载；此刻立即断言可达性——
        // 缺陷时序中新树 onAppear 可能先跑（绑定）而旧树 onDisappear 后跑
        // （解绑清空），旧实现在此刻 onToggle 已为 nil 且无自愈路径。
        try await waitFor { state.received.contains(nil) }
        XCTAssertNil(state.coordinator.expandedKind, "onDisappear 应折叠展开状态")
        print("[lctest] 旧树已卸载 mountCount=\(state.mountCount) received=\(state.received) toggleBound=\(state.coordinator.onToggle != nil)")

        // 4) 回归断言：卸载后 onToggle 仍可达，展开请求立即送达
        XCTAssertNotNil(
            state.coordinator.onToggle,
            "内容树卸载不得解绑 onToggle（旧实例 onDisappear 晚于新实例 onAppear 时会清掉新绑定，展开请求永丢）"
        )
        state.coordinator.open(.gpu)
        try await waitFor { state.received.last == .gpu }
        XCTAssertEqual(state.received.last, .gpu, "卸载后展开请求应仍到达宿主接线")

        window.orderOut(nil)
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { XCTFail("等待条件超时") }
    }

    private func mountLifecycleHarness(_ state: LifecycleHarnessState) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: LifecycleHostHarness(state: state)
        )
        window.orderFrontRegardless()
        return window
    }
}

/// 挂载状态：coordinator/monitor 由 harness 持有，跨内容树重建存续
/// （与生产中由宿主 ControlCenterContainerView 持有的语义一致）。
@MainActor
final class LifecycleHarnessState: ObservableObject {
    let coordinator = ProcessBreakdownCoordinator()
    let monitor = makeFakeMonitor()
    /// 宿主 onExpandedMetric 接线收到的指标序列（nil = close 折叠）
    private(set) var received: [ProcessMetricKind?] = []
    /// 内容树重建令牌（.id()）：变化触发旧树卸载 + 新树挂载
    @Published var rebuildToken = 0
    @Published var route: MonitorPanelRoute = .overview
    /// 挂载次数（onAppear 计数）
    private(set) var mountCount = 0

    func handleExpandedMetric(_ kind: ProcessMetricKind?) {
        received.append(kind)
        monitor.setExpandedProcessMetric(kind)
    }

    func mounted() { mountCount += 1 }
}

private struct LifecycleHostHarness: View {
    @ObservedObject var state: LifecycleHarnessState
    @StateObject private var diskProtection = DiskProtectionService()

    var body: some View {
        MonitorContainerView(
            coordinator: state.coordinator,
            diskProtection: diskProtection,
            route: $state.route,
            monitor: state.monitor,
            configuration: MonitorConfiguration(),
            strings: .en,
            onDemandChange: { _ in },
            onExpandedMetric: { state.handleExpandedMetric($0) },
            onStartSpeedTest: {},
            showsSettingsAction: false
        )
        .onAppear { state.mounted() }
        .id(state.rebuildToken)
    }
}
