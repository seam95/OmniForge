import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 阶段 0 基线探针（已随迁移完成收尾）：旧双树转场结构（ZStack + pushTransition）
/// 已删除，S3/S4 改用统一 PageSwitchHost。本文件保留为真实监控视图的
/// 单活动树挂载计数验证（结构与阶段 1 Host 单测互补）与阶段 8 对比基线。
@MainActor
final class PageSwitchBaselineProbeTests: XCTestCase {

    // MARK: - S3：真实 MonitorContainerView 单活动树（阶段 7 迁移后）

    /// 监控层级切换（overview ↔ diskDetail）期间任意时刻最多一棵完整页面树。
    /// 计数挂在真实内容分支（pageMountObserver），以「转场各阶段稳态采样」断言：
    /// exiting 中点（旧页独占）与 entering 中点（新页独占）在途树数必须为 1；
    /// 若恢复双树转场（ZStack 叠放），exiting 中点两树并存 → 采样为 2 → 变红。
    ///
    /// 框架行为记录：SwiftUI 同位置树交换时新页 onAppear 可先于旧页
    /// onDisappear 触发，裸峰值计数会出现瞬时 2（替换瞬态，旧树已标记移除且
    /// opacity 0，不参与渲染）——单树保证以结构与稳态采样为准，不断言裸峰值。
    func test_probeA_monitorHierarchySwitch_keepsSingleActiveTree() async throws {
        let mounts = PageMounts()
        _ = try mountMonitor(mounts: mounts)

        try await tick(0.05)
        XCTAssertEqual(mounts.current, 1, "sanity：初始仅 overview 挂载")
        XCTAssertEqual(mounts.lastMountedPage, .overview)

        mounts.route = .diskDetail
        try await tick(0.03) // exiting 中点（exit 70ms 内）：旧页独占
        let duringExit = mounts.current
        try await waitFor { mounts.lastMountedPage == .diskDetail }
        try await tick(0.06) // entering 中点：新页独占
        let duringEnter = mounts.current

        XCTAssertEqual(duringExit, 1, "退出阶段在途页面树必须唯一")
        XCTAssertEqual(duringEnter, 1, "进入阶段在途页面树必须唯一")

        mounts.route = .overview
        try await tick(0.03)
        let duringBackExit = mounts.current
        try await waitFor { mounts.lastMountedPage == .overview }
        XCTAssertEqual(duringBackExit, 1)
        baselineRecord("S3 真实监控层级切换稳态在途树数：exit=\(duringExit) enter=\(duringEnter)")
    }

    // MARK: - 探针 B：离开监控页主线程阻塞（阶段 3 已修复）

    func test_probeB_leavingMonitorWhileSampling_returnsImmediately() {
        let manager = SystemMonitorManager(
            scheduler: TestRepeatingScheduler(),
            cpuSampler: SlowCPUSampler(delay: 0.3),
            gpuSampler: TestGPUSampler(),
            memorySampler: TestMemorySampler(),
            temperatureSampler: TestTemperatureSampler(),
            networkSampler: TestNetworkSampler(),
            diskSampler: TestDiskSampler(),
            powerSampler: TestPowerSampler(),
            peripheralBatterySampler: TestPeripheralBatterySampler(),
            processSampler: TestProcessUsageSampler()
        )
        manager.setPanelDemand(.init(system: true))
        Self.tick(0.02)

        let start = CFAbsoluteTimeGetCurrent()
        manager.setPanelDemand(.none)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        baselineRecord(String(format: "离开监控页主线程阻塞：%.4fs", elapsed))
        XCTAssertLessThanOrEqual(elapsed, 0.01, "停止采样不得等待采样队列（SPEC §9.1.2）")
    }

    // MARK: - 探针 C：20 次往返基线（与 BASELINE.md 阶段 0 对比）

    func test_probeC_twentyRoundTrips_wallTimeBaseline() async throws {
        let mounts = PageMounts()
        _ = try mountMonitor(mounts: mounts)
        try await tick(0.05)

        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<20 {
            mounts.route = index.isMultiple(of: 2) ? .diskDetail : .overview
            try await tick(0.02)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        // 等最后一轮转场收敛：以「实际展示页面」断言结果（不只验证请求值）；
        // 稳态在途树数恒 1（裸峰值含 SwiftUI 替换瞬态，见 probeA 框架行为记录）。
        try await waitFor {
            mounts.current == 1 && mounts.lastMountedPage == .overview
        }
        baselineRecord(String(format: "20 次往返切换总耗时（debug 构建）：%.3fs", elapsed))
        XCTAssertEqual(mounts.route, .overview, "sanity：最终请求 route 正确")
    }

    // MARK: - 基础设施

    private static func tick(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }

    private func tick(_ duration: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    private func waitFor(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { XCTFail("等待条件超时") }
    }

    private func baselineRecord(_ message: String) {
        print("[baseline] \(name) — \(message)")
    }
}

/// 挂载真实 MonitorContainerView 并返回宿主窗口；页面挂载经
/// `pageMountObserver` 在真实内容分支上计数（SPEC §6.3.5）。
@MainActor
private func mountMonitor(mounts: PageMounts) throws -> NSWindow {
    let harness = MonitorHostHarness(mounts: mounts)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(rootView: harness)
    window.orderFrontRegardless()
    return window
}

private struct MonitorHostHarness: View {
    @ObservedObject var mounts: PageMounts
    @ObservedObject private var monitor = makeFakeMonitor()
    @StateObject private var coordinator = ProcessBreakdownCoordinator()
    @StateObject private var diskProtection = DiskProtectionService()

    var body: some View {
        MonitorContainerView(
            coordinator: coordinator,
            diskProtection: diskProtection,
            route: $mounts.route,
            monitor: monitor,
            configuration: MonitorConfiguration(),
            strings: .en,
            onDemandChange: { _ in },
            onExpandedMetric: { _ in },
            onStartSpeedTest: {},
            pageMountObserver: { page, delta in mounts.bump(page, delta) }
        )
    }
}

/// 真实页面分支挂载计数：峰值（单活动树断言）+ 最后挂载的页面身份
/// （对 SwiftUI 转场期 onAppear 可能的重复触发免疫，收敛语义看终值）。
@MainActor
final class PageMounts: ObservableObject {
    @Published var route: MonitorPanelRoute = .overview
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var lastMountedPage: MonitorPanelRoute?

    func bump(_ page: MonitorPanelRoute, _ delta: Int) {
        current += delta
        peak = max(peak, current)
        if delta > 0 { lastMountedPage = page }
    }
}

/// 慢 CPU 采样器：模拟真实 GPU/proc 采样耗时，阻塞串行采样队列。
private final class SlowCPUSampler: CPUUsageSampling {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }

    func sample() throws -> CPUUsageReading? {
        Thread.sleep(forTimeInterval: delay)
        return CPUUsageReading(total: 0.5, user: 0.3, system: 0.2)
    }
}
