import XCTest
@testable import OmniForge

final class MonitorPanelRouteTests: XCTestCase {
    func test_routeEquatable() {
        XCTAssertEqual(MonitorPanelRoute.overview, .overview)
        XCTAssertEqual(MonitorPanelRoute.ranking(.cpu), .ranking(.cpu))
        XCTAssertNotEqual(MonitorPanelRoute.ranking(.cpu), .ranking(.memory))
        XCTAssertEqual(MonitorPanelRoute.diskDetail, .diskDetail)
        XCTAssertNotEqual(MonitorPanelRoute.diskDetail, .overview)
        XCTAssertNotEqual(MonitorPanelRoute.diskDetail, .ranking(.cpu))
    }

    func test_coordinator_openAlwaysExpandsEvenIfSameKind() {
        let coordinator = ProcessBreakdownCoordinator()
        var events: [ProcessMetricKind?] = []
        coordinator.onToggle = { events.append($0) }
        coordinator.open(.cpu)
        coordinator.open(.cpu)
        XCTAssertEqual(coordinator.expandedKind, .cpu)
        XCTAssertEqual(events, [.cpu, .cpu])
    }

    func test_coordinator_closeClears() {
        let coordinator = ProcessBreakdownCoordinator()
        var events: [ProcessMetricKind?] = []
        coordinator.onToggle = { events.append($0) }
        coordinator.open(.gpu)
        coordinator.close()
        XCTAssertNil(coordinator.expandedKind)
        XCTAssertEqual(events, [.gpu, nil])
    }

    func test_coordinator_openReplacesKind() {
        let coordinator = ProcessBreakdownCoordinator()
        var events: [ProcessMetricKind?] = []
        coordinator.onToggle = { events.append($0) }
        coordinator.open(.cpu)
        coordinator.open(.memory)
        XCTAssertEqual(coordinator.expandedKind, .memory)
        XCTAssertEqual(events, [.cpu, .memory])
    }
}
