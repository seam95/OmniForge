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

    func test_defaultConfiguration_producesMetricsNetworkDiskBattery() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        XCTAssertEqual(sections.map(\.id), [
            "section.metrics", "section.network", "section.disk", "section.battery",
        ])
        guard case let .metrics(metrics) = sections.first else {
            return XCTFail("首分区应为三列指标区")
        }
        XCTAssertEqual(metrics.map(\.id), [.cpu, .gpu, .memory])
    }

    func test_hidingSingleMetric_keepsSingleMetricsSection() {
        var config = MonitorConfiguration()
        config.visiblePanelMetrics.remove(.gpu)
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.metrics", "section.network", "section.disk", "section.battery",
        ])
        guard case let .metrics(metrics) = sections.first else {
            return XCTFail("首分区应为三列指标区")
        }
        XCTAssertEqual(metrics.map(\.id), [.cpu, .memory])
    }

    func test_hidingSystemSection_removesMetricsSectionEntirely() {
        var config = MonitorConfiguration()
        config.visibleSections = [.network, .disk, .power]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.network", "section.disk", "section.battery",
        ])
    }

    func test_hidingBatterySection_keepsDiskAsFullWidth() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network, .disk]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.metrics", "section.network", "section.disk",
        ])
    }

    func test_hidingDiskSection_keepsBatteryAsFullWidth() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network, .power]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.metrics", "section.network", "section.battery",
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
        for section in sections.dropFirst() {
            XCTAssertNotNil(section.model, "非三列分区应携带单一卡模型")
        }
        XCTAssertNil(sections.first?.model, "三列分区无单一模型")
    }

    func test_everySectionExposesAccentCardID() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        for section in sections {
            XCTAssertNotNil(section.accentCardID)
        }
        XCTAssertEqual(sections.first?.accentCardID, .cpu, "三列分区主色取首列（CPU）")
    }
}
