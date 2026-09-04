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
    func test_probeA_monitorHierarchySwitch_keepsSingleActiveTree() async throws {
        let counter = MountCounter()
        let box = RouteBox(route: .overview)
        let monitor = makeFakeMonitor()
        let harness = MonitorHostHarness(
            route: box.binding,
            monitor: monitor,
            counter: counter
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: harness)
        window.orderFrontRegardless()
        try await tick(0.05)
        XCTAssertEqual(counter.current, 1, "sanity：初始仅 overview 挂载")

        box.route = .diskDetail
        try await tick(0.05)
        try await waitFor { counter.current == 1 }
        XCTAssertEqual(counter.peak, 1, "真实监控层级切换期间最多一棵页面树")

        box.route = .overview
        try await tick(0.05)
        try await waitFor { counter.current == 1 }
        XCTAssertEqual(counter.peak, 1)
        baselineRecord("S3 真实监控层级往返切换单活动树峰值：\(counter.peak)")
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
        let counter = MountCounter()
        let box = RouteBox(route: .overview)
        let monitor = makeFakeMonitor()
        let harness = MonitorHostHarness(route: box.binding, monitor: monitor, counter: counter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: harness)
        window.orderFrontRegardless()
        try await tick(0.05)

        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<20 {
            box.route = index.isMultiple(of: 2) ? .diskDetail : .overview
            try await tick(0.02)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        baselineRecord(String(format: "20 次往返切换总耗时（debug 构建）：%.3fs", elapsed))
        baselineRecord("20 次往返峰值同时挂载页面树数：\(counter.peak)")
        XCTAssertEqual(box.route, .overview, "sanity：最终 route 正确")
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

/// 真实 MonitorContainerView harness：挂载数经内容视图 onAppear/onDisappear 计数。
private struct MonitorHostHarness: View {
    @Binding var route: MonitorPanelRoute
    @ObservedObject var monitor: SystemMonitorManager
    let counter: MountCounter
    @StateObject private var coordinator = ProcessBreakdownCoordinator()
    @StateObject private var diskProtection = DiskProtectionService()

    var body: some View {
        MonitorContainerView(
            coordinator: coordinator,
            diskProtection: diskProtection,
            route: $route,
            monitor: monitor,
            configuration: MonitorConfiguration(),
            strings: .en,
            onDemandChange: { _ in },
            onExpandedMetric: { _ in },
            onStartSpeedTest: {}
        )
        .onAppear { counter.bump(+1) }
        .onDisappear { counter.bump(-1) }
    }
}

/// 页面树挂载计数器。
@MainActor
final class MountCounter {
    private(set) var current = 0
    private(set) var peak = 0

    func bump(_ delta: Int) {
        current += delta
        peak = max(peak, current)
    }
}

/// 外部持有的 route 状态盒。
@MainActor
final class RouteBox: ObservableObject {
    @Published var route: MonitorPanelRoute

    init(route: MonitorPanelRoute) {
        self.route = route
    }

    var binding: Binding<MonitorPanelRoute> {
        Binding(get: { self.route }, set: { self.route = $0 })
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
