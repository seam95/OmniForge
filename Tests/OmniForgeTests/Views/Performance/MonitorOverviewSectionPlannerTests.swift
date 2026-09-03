import XCTest
@testable import OmniForge

final class MonitorOverviewSectionPlannerTests: XCTestCase {
    private func buildModels(
        configuration: MonitorConfiguration = MonitorConfiguration()
    ) -> [MonitorCardModel] {
        MonitorCardModelBuilder.models(
            snapshot: SystemSnapshot(),
            configuration: configuration,
            strings: .en,
            temperatureUnit: .celsius,
            history: MetricHistory()
        )
    }

    func test_defaultConfiguration_producesMetricSectionsNetworkAndDiskBattery() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        XCTAssertEqual(sections.map(\.id), [
            "section.metric.cpu", "section.metric.gpu", "section.metric.memory",
            "section.network", "section.diskBattery",
        ])
        guard case let .diskBattery(disk, battery) = sections.last else {
            return XCTFail("末分区应为磁盘+电池两栏")
        }
        XCTAssertEqual(disk.id, .disk)
        XCTAssertEqual(battery.id, .battery)
    }

    func test_hidingSingleMetric_removesThatMetricSectionOnly() {
        var config = MonitorConfiguration()
        config.visiblePanelMetrics.remove(.gpu)
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.metric.cpu", "section.metric.memory",
            "section.network", "section.diskBattery",
        ])
    }

    func test_hidingSystemSection_removesMetricSectionsEntirely() {
        var config = MonitorConfiguration()
        config.visibleSections = [.network, .disk, .power]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.network", "section.diskBattery",
        ])
    }

    func test_hidingBatterySection_keepsDiskAsFullWidth() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network, .disk]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.metric.cpu", "section.metric.gpu", "section.metric.memory",
            "section.network", "section.disk",
        ])
    }

    func test_hidingDiskSection_keepsBatteryAsFullWidth() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network, .power]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.metric.cpu", "section.metric.gpu", "section.metric.memory",
            "section.network", "section.battery",
        ])
    }

    func test_hidingAllSections_producesEmpty() {
        var config = MonitorConfiguration()
        config.visibleSections = []
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertTrue(sections.isEmpty)
    }

    func test_singleModelSectionsCarryCardData() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        for section in sections.dropLast() {
            XCTAssertNotNil(section.model)
        }
    }

    func test_everySectionExposesAccentCardID() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        for section in sections {
            XCTAssertNotNil(section.accentCardID)
        }
        if case let .diskBattery(disk, _) = sections.last {
            XCTAssertEqual(disk.id, .disk, "两栏分区主色取首栏（磁盘）")
        }
    }
}
