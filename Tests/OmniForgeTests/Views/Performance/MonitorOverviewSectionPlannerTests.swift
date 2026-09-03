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

    func test_defaultConfiguration_producesFourSectionsInOrder() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        XCTAssertEqual(sections.map(\.id), [
            "section.triple", "section.network", "section.disk", "section.battery",
        ])
        guard case let .triple(models) = sections.first else {
            return XCTFail("首分区应为三栏")
        }
        XCTAssertEqual(models.map(\.id), [.cpu, .gpu, .memory])
    }

    func test_hidingSingleMetric_shrinksTripleButKeepsOrder() {
        var config = MonitorConfiguration()
        config.visiblePanelMetrics.remove(.gpu)
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        guard case let .triple(models) = sections.first else {
            return XCTFail("首分区应为三栏")
        }
        XCTAssertEqual(models.map(\.id), [.cpu, .memory])
        XCTAssertEqual(sections.count, 4)
    }

    func test_hidingSystemSection_removesTripleEntirely() {
        var config = MonitorConfiguration()
        config.visibleSections = [.network, .disk, .power]
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertEqual(sections.map(\.id), [
            "section.network", "section.disk", "section.battery",
        ])
    }

    func test_hidingAllSections_producesEmpty() {
        var config = MonitorConfiguration()
        config.visibleSections = []
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels(configuration: config))
        XCTAssertTrue(sections.isEmpty)
    }

    func test_sectionModelsCarryCardData() {
        let sections = MonitorOverviewSectionPlanner.sections(from: buildModels())
        for section in sections.dropFirst() {
            XCTAssertNotNil(section.model)
        }
    }
}
