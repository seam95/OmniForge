import XCTest
@testable import OmniForge

@MainActor
final class MonitorPanelRoutingTests: XCTestCase {
    func test_flatMonitorDemand_aggregatesVisibleSections() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network]
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
