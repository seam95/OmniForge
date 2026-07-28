import XCTest
@testable import OmniForge

final class MonitorOverviewCardGroupTests: XCTestCase {
    func test_groups_combinesBatteryAndEnergyAtBatteryPosition() {
        let battery = model(id: .battery)
        let energy = model(id: .energy, processMetricKind: .energy)
        let groups = MonitorOverviewCardGroup.groups(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            battery,
            model(id: .disk),
            model(id: .network, processMetricKind: .network),
            model(id: .gpu, processMetricKind: .gpu),
            energy
        ])

        XCTAssertEqual(groups.map(\.id), [
            "metric.cpu",
            "metric.memory",
            "power.battery-energy",
            "metric.disk",
            "metric.network",
            "metric.gpu"
        ])
        XCTAssertEqual(groups[2], .power(battery: battery, energy: energy))
    }

    func test_groups_dropsStandaloneEnergyWhenBatteryExists() {
        let groups = MonitorOverviewCardGroup.groups(from: [
            model(id: .battery),
            model(id: .energy, processMetricKind: .energy)
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertNotNil(groups.first?.energyModel)
    }

    func test_groups_keepsEnergyMetricWhenBatteryIsNotVisible() {
        let energy = model(id: .energy, processMetricKind: .energy)
        let groups = MonitorOverviewCardGroup.groups(from: [
            model(id: .cpu, processMetricKind: .cpu),
            energy
        ])

        XCTAssertEqual(groups, [
            .metric(model(id: .cpu, processMetricKind: .cpu)),
            .metric(energy)
        ])
    }

    func test_groups_powerGroupUsesSingleColumnWidth() {
        let groups = MonitorOverviewCardGroup.groups(from: [
            model(id: .battery),
            model(id: .energy, processMetricKind: .energy),
            model(id: .network, processMetricKind: .network)
        ])

        XCTAssertFalse(groups[0].isFullWidth)
        XCTAssertTrue(groups[1].isFullWidth)
    }

    func test_groups_energyModelPreservesRankingKind() {
        let groups = MonitorOverviewCardGroup.groups(from: [
            model(id: .battery),
            model(id: .energy, processMetricKind: .energy)
        ])

        XCTAssertEqual(groups.first?.energyModel?.processMetricKind, .energy)
    }

    func test_dashboardRows_prioritizePowerAndDiskAsFullWidthRows() {
        let battery = model(id: .battery)
        let energy = model(id: .energy, processMetricKind: .energy)
        let disk = model(id: .disk)
        let network = model(id: .network, processMetricKind: .network)
        let gpu = model(id: .gpu, processMetricKind: .gpu)
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            battery,
            disk,
            network,
            gpu,
            energy
        ])

        XCTAssertEqual(rows.map(\.id), [
            "row.top",
            "row.power",
            "row.disk",
            "row.bottom"
        ])
        XCTAssertEqual(rows[1], .single(.power(battery: battery, energy: energy), id: "row.power"))
        XCTAssertEqual(rows[2], .single(.metric(disk), id: "row.disk"))
        XCTAssertEqual(rows[3], .pair(.metric(network), .metric(gpu), id: "row.bottom"))
    }

    func test_dashboardRows_makesNetworkFullWidthWhenGpuHidden() {
        let network = model(id: .network, processMetricKind: .network)
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            network
        ])

        XCTAssertEqual(rows.map(\.id), [
            "row.top",
            "row.bottom"
        ])
        XCTAssertEqual(rows.last, .single(.metric(network), id: "row.bottom"))
    }

    func test_dashboardRows_defineReferenceStyleHeightsAndKinds() {
        let rows = MonitorOverviewCardGroup.dashboardRows(from: [
            model(id: .cpu, processMetricKind: .cpu),
            model(id: .memory, processMetricKind: .memory),
            model(id: .battery),
            model(id: .disk),
            model(id: .network, processMetricKind: .network),
            model(id: .gpu, processMetricKind: .gpu),
            model(id: .energy, processMetricKind: .energy)
        ])

        XCTAssertEqual(rows.map(\.height), [122, 78, 88, 104])
        XCTAssertEqual(rows[0].displayKinds, [.cpuGauge, .memoryDashboard])
        XCTAssertEqual(rows[1].displayKinds, [.powerStrip])
        XCTAssertEqual(rows[2].displayKinds, [.diskThroughput])
        XCTAssertEqual(rows[3].displayKinds, [.metric, .metric])
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
