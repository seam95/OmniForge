import XCTest
@testable import OmniForge

final class MonitorCardIDTests: XCTestCase {
    func test_defaultConfiguration_includesCoreCardsInOrder() {
        let config = MonitorConfiguration()
        let cards = MonitorCardID.visibleCards(configuration: config)
        let core = cards.filter { [.cpu, .memory, .battery, .disk, .network].contains($0) }
        XCTAssertEqual(core, [.cpu, .memory, .battery, .disk, .network])
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
    }

    func test_hidingCpuMetric_removesOnlyCpuCard() {
        var config = MonitorConfiguration()
        config.visiblePanelMetrics.remove(.cpu)
        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertFalse(cards.contains(.cpu))
        XCTAssertTrue(cards.contains(.memory))
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

    func test_networkIsFullWidth() {
        XCTAssertTrue(MonitorCardID.network.isFullWidth)
        XCTAssertFalse(MonitorCardID.cpu.isFullWidth)
        XCTAssertFalse(MonitorCardID.disk.isFullWidth)
    }

    func test_extensionCards_followPanelSectionOrder() {
        var config = MonitorConfiguration()
        // Default metrics already include gpu/disk/power; force all sections visible.
        config.visibleSections = Set(MonitorSection.allCases)
        config.panelSectionOrder = [.power, .disk, .system, .network]

        let cards = MonitorCardID.visibleCards(configuration: config)
        let core: [MonitorCardID] = [.cpu, .memory, .battery, .disk, .network]
        let extensions = cards.filter { !core.contains($0) }
        // power → energy, system → gpu（disk 已并入核心卡，不再有 diskIO 扩展卡）
        XCTAssertEqual(extensions, [.energy, .gpu])

        config.panelSectionOrder = [.system, .network, .disk, .power]
        let cardsDefaultish = MonitorCardID.visibleCards(configuration: config)
        let extensionsDefaultish = cardsDefaultish.filter { !core.contains($0) }
        XCTAssertEqual(extensionsDefaultish, [.gpu, .energy])
    }

    func test_extensionCards_stillRespectVisibility() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .disk]
        config.visiblePanelMetrics = [.cpu, .memory, .gpu, .disk]
        config.panelSectionOrder = [.disk, .system, .network, .power]

        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertFalse(cards.contains(.energy))
        XCTAssertFalse(cards.contains(.battery))
        XCTAssertFalse(cards.contains(.network))
        XCTAssertTrue(cards.contains(.disk))
        let extensions = cards.filter { [.gpu, .energy].contains($0) }
        XCTAssertEqual(extensions, [.gpu])
    }

    func test_diskCard_isCoreAndNotExtension() {
        var config = MonitorConfiguration()
        config.visibleSections = Set(MonitorSection.allCases)
        config.visiblePanelMetrics = Set(MonitorMetric.allCases)
        let cards = MonitorCardID.visibleCards(configuration: config)
        XCTAssertTrue(cards.contains(.disk))
        // 扩展卡仅剩 gpu / energy
        let extensions = cards.filter { ![.cpu, .memory, .battery, .disk, .network].contains($0) }
        XCTAssertEqual(Set(extensions), Set([.gpu, .energy]))
    }
}
