import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 阶段 0 基线探针：量化现状页面切换行为，证明 SPEC §2 所列问题真实存在
/// 且现有测试套件未覆盖。探针只做记录型断言（sanity），
/// 数据以 `[baseline]` 前缀输出到测试日志并回填 BASELINE.md；
/// 对应阶段迁移完成后，本文件的断言将收紧为 SPEC 不变量（单活动树等）。
@MainActor
final class PageSwitchBaselineProbeTests: XCTestCase {

    // MARK: - 探针 A：转场窗口内双活动页面树（SPEC §2.1 / §6.3）

    /// 监控页层级切换（overview → diskDetail）。harness 复刻 `MonitorContainerView`
    /// 的转场结构（ZStack + switch + pushTransition + pageTransition 动画，参数一致），
    /// 子页面用真实视图，挂载数经 onAppear/onDisappear 计数。
    ///
    /// 离屏局限（基线实测）：XCTest 进程无动画时钟，SwiftUI 转场在此环境同步完成
    /// （旧视图移除与新视图插入同事务），峰值挂载数恒为 1 —— 双树行为在离屏环境
    /// 不可复现，只能经结构审查（ZStack+AnyTransition 语义上转场期新旧分支共存）
    /// 与真机验收矩阵（SPEC §13.3）验证。阶段 1 的 Host 以结构方式保证单树：
    /// 内容闭包只消费 displayedRoute，route 交换发生在禁用动画的 Transaction。
    func test_probeA_hierarchySwitch_mountedPageTreeCount() throws {
        let counter = MountCounter()
        let box = RouteBox(route: .overview)
        let harness = SwitchProbeHarness(route: box.binding, counter: counter)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: harness)
        window.contentView = hosting
        window.orderFrontRegardless()
        Self.tick(0.05)
        XCTAssertEqual(counter.current, 1, "sanity：初始仅 overview 挂载")

        box.route = .diskDetail
        Self.tick(0.08)

        baselineRecord(
            "S3 层级切换转场窗口内峰值同时挂载页面树数（离屏）：\(counter.peakSimultaneous)（离屏无动画时钟，真实窗口为 2，见 BASELINE.md 结构审查）"
        )
        XCTAssertEqual(counter.current, 1, "sanity：切换完成后仅 diskDetail 挂载")
    }

    // MARK: - 探针 B：离开监控页的主线程阻塞（SPEC §2.3）

    /// 采样队列正在执行慢采样时，主线程停止采样（离开监控页路径）
    /// 必须同步等待采样队列完成 —— 当前实现违反 SPEC §9.1.2。
    func test_probeB_leavingMonitorWhileSampling_blocksMainThread() {
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
        Self.tick(0.02) // 让慢采样已在串行队列上执行

        let start = CFAbsoluteTimeGetCurrent()
        manager.setPanelDemand(.none) // → stopSampling → queue.sync 等待采样队列
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        baselineRecord(String(format: "离开监控页主线程阻塞：%.3fs", elapsed))

        XCTAssertGreaterThan(
            elapsed, 0.2,
            "现状记录：主线程同步等待采样队列（阶段 3 修复后本断言反转为 ≤ 0.01s）"
        )
    }

    // MARK: - 探针 C：20 次往返切换基线（SPEC §12）

    func test_probeC_twentyRoundTrips_wallTimeBaseline() throws {
        let counter = MountCounter()
        let box = RouteBox(route: .overview)
        let harness = SwitchProbeHarness(route: box.binding, counter: counter)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: harness)
        window.orderFrontRegardless()
        Self.tick(0.05)

        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<20 {
            box.route = index.isMultiple(of: 2) ? .diskDetail : .overview
            Self.tick(0.03)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        baselineRecord(String(format: "20 次往返切换总耗时（debug 构建）：%.3fs", elapsed))
        baselineRecord("20 次往返峰值同时挂载页面树数：\(counter.peakSimultaneous)")

        XCTAssertEqual(box.route, .overview, "sanity：最终 route 正确")
    }

    // MARK: - 基础设施

    private static func tick(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
    }

    private func baselineRecord(_ message: String) {
        // 输出带前缀便于从测试日志收集回填 BASELINE.md。
        print("[baseline] \(name) — \(message)")
    }
}

/// 转场结构复刻 harness：与 `MonitorContainerView` 相同的 ZStack + pushTransition +
/// pageTransition 动画，子页面为真实视图；挂载数由计数器追踪。
private struct SwitchProbeHarness: View {
    @Binding var route: MonitorPanelRoute
    let counter: MountCounter

    var body: some View {
        ZStack {
            switch route {
            case .overview:
                MonitorOverviewView(
                    snapshot: SystemSnapshot(),
                    history: MetricHistory(),
                    configuration: MonitorConfiguration(),
                    strings: .en,
                    deviceSummary: DeviceSummary(
                        hostName: "ProbeHost",
                        osVersionText: nil,
                        uptimeText: nil
                    ),
                    onSelectRankable: { _ in },
                    onSelectDiskDetail: { self.route = .diskDetail },
                    onRefresh: {}
                )
                .pushTransition(from: .leading)
                .onAppear { counter.bump(+1) }
                .onDisappear { counter.bump(-1) }
            case .diskDetail:
                MonitorDiskDetailView(
                    snapshot: SystemSnapshot(),
                    strings: .en,
                    temperatureUnit: .celsius,
                    protection: DiskProtectionService(),
                    onBack: { self.route = .overview },
                    onOpenSettings: {},
                    showsSettingsAction: true,
                    onRefresh: {}
                )
                .pushTransition(from: .trailing)
                .onAppear { counter.bump(+1) }
                .onDisappear { counter.bump(-1) }
            case .ranking:
                EmptyView()
            }
        }
        .animation(Theme.Animation.pageTransition, value: route)
    }
}

/// 页面树挂载计数器（主线程使用）。
@MainActor
final class MountCounter {
    private(set) var current = 0
    private(set) var peakSimultaneous = 0

    func bump(_ delta: Int) {
        current += delta
        peakSimultaneous = max(peakSimultaneous, current)
    }
}

/// 外部持有的 route 状态盒：让测试能从宿主视图外驱动切换。
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
