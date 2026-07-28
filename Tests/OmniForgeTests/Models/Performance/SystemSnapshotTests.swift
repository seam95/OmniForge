import XCTest
@testable import OmniForge

final class SystemSnapshotTests: XCTestCase {
    func test_snapshotContainsNoHistoryStorage() {
        let snapshot = SystemSnapshot()
        XCTAssertNil(snapshot.cpuUsage)
        XCTAssertNil(snapshot.cpuTemperature)
        XCTAssertNil(snapshot.gpuUsage)
        XCTAssertNil(snapshot.memoryUsed)
        XCTAssertNil(snapshot.sampledAt)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertTrue(snapshot.peripheralBatteries.isEmpty)
    }

    func test_processBreakdownAllowsOnlyOneKind() {
        var state = ProcessBreakdownState.collapsed
        state = .loading(.cpu)
        XCTAssertEqual(state.kind, .cpu)
        state = .loading(.gpu)
        XCTAssertEqual(state.kind, .gpu)
    }

    func test_processBreakdownCollapsedKindIsNil() {
        let state = ProcessBreakdownState.collapsed
        XCTAssertNil(state.kind)
    }

    func test_processBreakdownAllCasesRoundTrip() {
        let cases: [(ProcessMetricKind, [ProcessUsage])] = [
            (.cpu, [ProcessUsage(pid: 1, name: "test", value: 0.5)]),
            (.memory, []),
            (.energy, []),
        ]
        for (kind, usages) in cases {
            let state = ProcessBreakdownState.loaded(kind, usages)
            XCTAssertEqual(state.kind, kind)
        }
    }

    func test_processBreakdownFailedPreservesKind() {
        let state = ProcessBreakdownState.failed(.network, "error")
        XCTAssertEqual(state.kind, .network)
    }

    func test_monitorDemandNoneIsAllFalse() {
        let demand = MonitorDemand.none
        XCTAssertFalse(demand.system)
        XCTAssertFalse(demand.network)
        XCTAssertFalse(demand.disk)
        XCTAssertFalse(demand.power)
        XCTAssertFalse(demand.cpu)
    }

    func test_monitorDemandEquality() {
        let a = MonitorDemand()
        var b = MonitorDemand()
        b.cpu = true
        XCTAssertNotEqual(a, b)
    }
}
