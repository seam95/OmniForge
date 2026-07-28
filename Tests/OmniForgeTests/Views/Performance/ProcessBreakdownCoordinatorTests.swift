import XCTest
@testable import OmniForge

final class ProcessBreakdownCoordinatorTests: XCTestCase {
    func test_openingGPUReplacesCPUAndClosingStopsGPU() {
        var events: [ProcessMetricKind?] = []
        let coordinator = ProcessBreakdownCoordinator()
        coordinator.onToggle = { events.append($0) }
        coordinator.toggle(.cpu)
        coordinator.toggle(.gpu)
        coordinator.toggle(.gpu)
        XCTAssertEqual(events, [.cpu, .gpu, nil])
        XCTAssertNil(coordinator.expandedKind)
    }

    func test_toggleSameKindCloses() {
        let coordinator = ProcessBreakdownCoordinator()
        coordinator.toggle(.cpu)
        XCTAssertEqual(coordinator.expandedKind, .cpu)
        coordinator.toggle(.cpu)
        XCTAssertNil(coordinator.expandedKind)
    }

    /// 同一指标再次点击应折叠，onToggle 收到 [.cpu, nil]
    func test_processBreakdownCoordinator_toggleSameKindCollapses() {
        let coordinator = ProcessBreakdownCoordinator()
        var received: [ProcessMetricKind?] = []
        coordinator.onToggle = { received.append($0) }
        coordinator.toggle(.cpu)
        coordinator.toggle(.cpu)
        XCTAssertEqual(received, [.cpu, nil])
    }
}
