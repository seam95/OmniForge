import XCTest
@testable import OmniForge

final class MonitorOverviewCardGroupTests: XCTestCase {
    func test_groups_flattenToMetricDirectly() {
        let groups = MonitorOverviewCardGroup.groups(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            model(id: .network, processMetricKind: .network),
            model(id: .battery),
            model(id: .gpu, processMetricKind: .gpu),
            model(id: .disk),
        ])

        XCTAssertEqual(groups.map(\.id), [
            "metric.cpu",
            "metric.memory",
            "metric.network",
            "metric.battery",
            "metric.gpu",
            "metric.disk"
        ])
    }

    func test_groups_keepsMetricModels() {
        let cpu = model(id: .cpu, processMetricKind: .cpu)
        let groups = MonitorOverviewCardGroup.groups(from: [cpu])
        XCTAssertEqual(groups.first?.metricModel, cpu)
    }

    func test_dashboardRows_fixedLayoutOrder() {
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            model(id: .network, processMetricKind: .network),
            model(id: .battery),
            model(id: .gpu, processMetricKind: .gpu),
            model(id: .disk),
        ])

        XCTAssertEqual(rows.map(\.id), [
            "row.cpuMemory",
            "row.network",
            "row.batteryGPU",
            "row.disk"
        ])
        XCTAssertEqual(rows[0], .pair(.metric(model(id: .cpu, processMetricKind: .cpu)), .metric(model(id: .memory, processMetricKind: .memory)), id: "row.cpuMemory"))
        XCTAssertEqual(rows[1], .single(.metric(model(id: .network, processMetricKind: .network)), id: "row.network"))
        XCTAssertEqual(rows[2], .pair(.metric(model(id: .battery)), .metric(model(id: .gpu, processMetricKind: .gpu)), id: "row.batteryGPU"))
        XCTAssertEqual(rows[3], .single(.metric(model(id: .disk)), id: "row.disk"))
    }

    func test_dashboardRows_fallBackToSingleWhenMateHidden() {
        // GPU 隐藏 → 电池独占 batteryGPU 行
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            model(id: .battery),
            model(id: .disk),
        ])
        XCTAssertEqual(rows.map(\.id), [
            "row.cpuMemory",
            "row.batteryGPU",
            "row.disk"
        ])
        XCTAssertEqual(rows[1], .single(.metric(model(id: .battery)), id: "row.batteryGPU"))
    }

    func test_dashboardRows_skipMissingRows() {
        // 隐藏 system（cpu/memory/gpu）与 network → 只剩磁盘
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .disk),
            model(id: .battery),
        ])
        XCTAssertEqual(rows.map(\.id), [
            "row.batteryGPU",
            "row.disk"
        ])
    }

    func test_dashboardRows_defineReferenceStyleHeightsAndKinds() {
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            model(id: .network, processMetricKind: .network),
            model(id: .battery),
            model(id: .gpu, processMetricKind: .gpu),
            model(id: .disk),
        ])

        XCTAssertEqual(rows.map(\.height), [150, 108, 110, 86])
        XCTAssertEqual(rows[0].displayKinds, [.cpuTrend, .memoryGauge])
        XCTAssertEqual(rows[1].displayKinds, [.networkDual])
        XCTAssertEqual(rows[2].displayKinds, [.batteryBar, .gpuTrend])
        XCTAssertEqual(rows[3].displayKinds, [.diskChips])
    }

    private func model(
        id: MonitorCardID,
        processMetricKind: ProcessMetricKind? = nil
    ) -> MonitorCardModel {
        MonitorCardModel(
            id: id,
            title: id.rawValue,
            systemImage: "circle",
            primaryText: id.rawValue,
            secondaryText: nil,
            progress: nil,
            badgeText: nil,
            showsLiveDot: false,
            issueText: nil,
            processMetricKind: processMetricKind
        )
    }
}
