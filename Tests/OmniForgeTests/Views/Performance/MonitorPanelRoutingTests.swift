import XCTest
@testable import OmniForge

@MainActor
final class MonitorPanelRoutingTests: XCTestCase {
    func test_flatMonitorDemand_aggregatesVisibleSections() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network]
        // panelSectionOrder 已不再参与需求计算（固定布局）
        config.panelSectionOrder = [.network, .system, .disk, .power]

        let demand = MonitorContainerView.demand(for: config)
        XCTAssertTrue(demand.system)
        XCTAssertTrue(demand.cpu)
        XCTAssertTrue(demand.gpu)
        XCTAssertTrue(demand.memory)
        XCTAssertTrue(demand.network)
        XCTAssertFalse(demand.disk)
        XCTAssertFalse(demand.power)
    }

    func test_flatMonitorDemand_emptyVisibleSectionsIsNone() {
        var config = MonitorConfiguration()
        config.visibleSections = []
        let demand = MonitorContainerView.demand(for: config)
        XCTAssertEqual(demand, .none)
    }

    func test_enteringMonitorSetsPanelDemand() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertTrue(monitor.isSampling)
    }

    func test_panelDemandGate_forcesNoneWhenSystemMonitorUnavailable() {
        let demand = MonitorDemand(system: true, cpu: true)
        XCTAssertEqual(
            MonitorPanelDemandGate.resolve(demand, isEnabled: true, isAvailable: false),
            .none
        )

        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(
            MonitorPanelDemandGate.resolve(demand, isEnabled: true, isAvailable: false)
        )
        XCTAssertFalse(monitor.isSampling)
    }

    func test_panelDemandGate_forcesNoneWhenConfigurationDisabled() {
        let demand = MonitorDemand(system: true, cpu: true)
        XCTAssertEqual(
            MonitorPanelDemandGate.resolve(demand, isEnabled: false, isAvailable: true),
            .none
        )
    }

    func test_panelDemandGate_passesThroughWhenSystemMonitorAvailable() {
        let demand = MonitorDemand(system: true, cpu: true)
        XCTAssertEqual(
            MonitorPanelDemandGate.resolve(demand, isEnabled: true, isAvailable: true),
            demand
        )
    }

    func test_panelDemandGate_unavailableWinsOverIsEnabled() {
        let demand = MonitorDemand(system: true, cpu: true)
        XCTAssertEqual(
            MonitorPanelDemandGate.resolve(demand, isEnabled: true, isAvailable: false),
            .none
        )
    }

    func test_leavingMonitorClearsPanelDemand() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))
        XCTAssertTrue(monitor.isSampling)
        monitor.setPanelDemand(.none)
        XCTAssertFalse(monitor.isSampling)
    }

    func test_leavingMonitorClearsExpandedProcessMetric() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))
        monitor.setExpandedProcessMetric(.cpu)
        XCTAssertEqual(monitor.processState.kind, .cpu)
        monitor.setExpandedProcessMetric(nil)
        XCTAssertNil(monitor.processState.kind)
    }

    func test_switchingProcessMetricStopsPrevious() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))
        monitor.setExpandedProcessMetric(.cpu)
        XCTAssertEqual(monitor.processState.kind, .cpu)
        monitor.setExpandedProcessMetric(.gpu)
        XCTAssertEqual(monitor.processState.kind, .gpu)
    }

    func test_menuBarMetricsDriveSampling() {
        let monitor = makeFakeMonitor()
        XCTAssertFalse(monitor.isSampling)
        monitor.setMenuBarMetrics([.cpu])
        XCTAssertTrue(monitor.isSampling)
        monitor.setMenuBarMetrics([])
        XCTAssertFalse(monitor.isSampling)
    }

    func test_alertRequirementsDriveSampling() {
        let monitor = makeFakeMonitor()
        XCTAssertFalse(monitor.isSampling)
        monitor.setAlertRequirements([.cpu])
        XCTAssertTrue(monitor.isSampling)
        monitor.setAlertRequirements([])
        XCTAssertFalse(monitor.isSampling)
    }

    /// 路由层：面板切回时若仍停在排名页，需恢复对应进程采样（切走时 close 已停止）。
    func test_rankingRestoration_returnsKindOnlyForRankingRoute() {
        XCTAssertEqual(MonitorContainerView.rankingRestoration(for: .ranking(.cpu)), .cpu)
        XCTAssertEqual(MonitorContainerView.rankingRestoration(for: .ranking(.memory)), .memory)
        XCTAssertNil(MonitorContainerView.rankingRestoration(for: .overview))
        XCTAssertNil(MonitorContainerView.rankingRestoration(for: .diskDetail))
    }

    /// 路由保留后，切走再切回的完整链路：close 停采样 → onAppear 恢复采样。
    func test_rankingRestoration_reopensExpandedMetricAfterReentry() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))

        let coordinator = ProcessBreakdownCoordinator()
        coordinator.onToggle = { monitor.setExpandedProcessMetric($0) }
        coordinator.open(.cpu)
        XCTAssertEqual(monitor.processState.kind, .cpu)

        // 切走面板：close 停止采样，但路由保留在 ranking。
        coordinator.close()
        XCTAssertNil(monitor.processState.kind)

        // 切回面板：按保留的路由恢复采样。
        let restored = MonitorContainerView.rankingRestoration(for: .ranking(.cpu))
        XCTAssertNotNil(restored)
        coordinator.open(restored!)
        XCTAssertEqual(monitor.processState.kind, .cpu)
    }

    /// 路由层：coordinator.toggle → onExpandedMetric → setExpandedProcessMetric
    func test_toggleBreakdown_setsExpandedProcessMetric() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))

        let coordinator = ProcessBreakdownCoordinator()
        coordinator.onToggle = { monitor.setExpandedProcessMetric($0) }

        coordinator.toggle(.cpu)
        XCTAssertEqual(monitor.processState.kind, .cpu)

        coordinator.toggle(.cpu)
        XCTAssertNil(monitor.processState.kind)
    }

    func test_openCard_setsExpandedAndImpliesRankingKind() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))
        let coordinator = ProcessBreakdownCoordinator()
        coordinator.onToggle = { monitor.setExpandedProcessMetric($0) }
        coordinator.open(.cpu)
        XCTAssertEqual(monitor.processState.kind, .cpu)
        coordinator.close()
        XCTAssertNil(monitor.processState.kind)
    }

    func test_refreshNow_doesNotCrashWhenSampling() {
        let monitor = makeFakeMonitor()
        monitor.setPanelDemand(.init(system: true, cpu: true))
        monitor.refreshNow()
        XCTAssertTrue(monitor.isSampling)
    }
}
