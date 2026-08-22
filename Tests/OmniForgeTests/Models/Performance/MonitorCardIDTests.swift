import XCTest
@testable import OmniForge

final class MonitorCardIDTests: XCTestCase {
    func test_defaultConfiguration_includesFixedOrderCards() {
        let config = MonitorConfiguration()
        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertEqual(cards, [.cpu, .memory, .network, .battery, .gpu, .disk])
    }

    func test_hidingSystemSection_removesCpuMemoryGpu() {
        var config = MonitorConfiguration()
        config.visibleSections = [.network, .disk, .power]
        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertFalse(cards.contains(.cpu))
        XCTAssertFalse(cards.contains(.memory))
        XCTAssertFalse(cards.contains(.gpu))
        XCTAssertTrue(cards.contains(.network))
        XCTAssertTrue(cards.contains(.disk))
        XCTAssertTrue(cards.contains(.battery))
    }

    func test_hidingCpuMetric_removesOnlyCpuCard() {
        var config = MonitorConfiguration()
        config.visiblePanelMetrics.remove(.cpu)
        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertFalse(cards.contains(.cpu))
        XCTAssertTrue(cards.contains(.memory))
    }

    func test_energyNeverAppearsInOverview() {
        let config = MonitorConfiguration()
        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertFalse(cards.contains(.energy))
    }

    func test_rankableKinds() {
        XCTAssertEqual(MonitorCardID.cpu.processMetricKind, .cpu)
        XCTAssertEqual(MonitorCardID.gpu.processMetricKind, .gpu)
        XCTAssertEqual(MonitorCardID.memory.processMetricKind, .memory)
        XCTAssertEqual(MonitorCardID.network.processMetricKind, .network)
        XCTAssertEqual(MonitorCardID.energy.processMetricKind, .energy)
        XCTAssertNil(MonitorCardID.battery.processMetricKind)
        XCTAssertNil(MonitorCardID.disk.processMetricKind)
    }

    func test_fixedOrderIgnoresPanelSectionOrder() {
        var config = MonitorConfiguration()
        config.visibleSections = Set(MonitorSection.allCases)
        config.panelSectionOrder = [.power, .disk, .system, .network]

        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertEqual(cards, [.cpu, .memory, .network, .battery, .gpu, .disk])
    }
}
