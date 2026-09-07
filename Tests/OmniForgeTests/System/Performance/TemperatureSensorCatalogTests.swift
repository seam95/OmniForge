import XCTest
import OmniForgeSMC
@testable import OmniForge

final class TemperatureSensorCatalogTests: XCTestCase {

    private func makeMock(keys: [String], values: [String: Double]) -> MockFanSMCCommanding {
        let mock = MockFanSMCCommanding()
        mock.keyNames = keys
        mock.doubleValues = values
        return mock
    }

    func test_sampleSensors_discoversOnlyTKeysWithPlausibleValues() throws {
        let mock = makeMock(
            keys: ["FNum", "Tp01", "TB0T", "TH0a"],
            values: ["Tp01": 45, "TB0T": 30, "TH0a": 41, "FNum": 2]
        )

        let sensors = try TemperatureSensorCatalog(smc: mock).sampleSensors()

        XCTAssertEqual(sensors.map(\.id), ["Tp01", "TH0a", "TB0T"],
                       "非 T 前缀排除；热区序 cpu → ssd → battery")
    }

    func test_sampleSensors_filtersImplausibleValues() throws {
        let mock = makeMock(
            keys: ["Tp01", "Tp05", "TB0T"],
            values: ["Tp01": 0.5, "Tp05": 130, "TB0T": 28]
        )

        let sensors = try TemperatureSensorCatalog(smc: mock).sampleSensors()

        XCTAssertEqual(sensors.map(\.id), ["TB0T"], "0.5°C 与 130°C 超出值域视为不存在")
    }

    func test_sampleSensors_locksActiveSetAfterDiscovery() throws {
        let mock = makeMock(keys: ["Tp01"], values: ["Tp01": 45])
        let catalog = TemperatureSensorCatalog(smc: mock)
        _ = try catalog.sampleSensors()

        // 发现后 SMC 又出现新 key — 已锁定的活跃集不再枚举
        mock.keyNames = ["Tp01", "TA0P"]
        mock.doubleValues["TA0P"] = 25
        mock.readDoubleKeys.removeAll()
        let sensors = try catalog.sampleSensors()

        XCTAssertEqual(sensors.map(\.id), ["Tp01"])
        XCTAssertFalse(mock.readDoubleKeys.contains("TA0P"), "锁定后不读新增 key")
        XCTAssertFalse(mock.readDoubleKeys.contains("FNum"), "不读非活跃 key")
    }

    func test_sampleSensors_dropsSensorWhenValueTurnsImplausible() throws {
        let mock = makeMock(keys: ["Tp01", "TB0T"], values: ["Tp01": 45, "TB0T": 30])
        let catalog = TemperatureSensorCatalog(smc: mock)
        _ = try catalog.sampleSensors()

        mock.doubleValues["Tp01"] = -10
        let sensors = try catalog.sampleSensors()

        XCTAssertEqual(sensors.map(\.id), ["TB0T"], "活跃 key 本轮读值异常则缺席本轮")
    }

    func test_label_knownKeyMapsFriendlyName() {
        XCTAssertEqual(TemperatureSensorCatalog.label(for: "TB0T"), "Battery Zone 1")
    }

    func test_label_unknownKeyKeepsRawCode() {
        XCTAssertEqual(TemperatureSensorCatalog.label(for: "TA0X"), "TA0X")
    }
}

final class ThermalZoneTests: XCTestCase {

    func test_zone_prefixRules() {
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "Tp01"), .cpu, "小写 p = P-core")
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "Te05"), .cpu, "e-core")
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "Tc0a"), .cpu, "M1 核心键")
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TC0P"), .cpu, "CPU 封装")
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TPDX"), .gpu, "大写 P = GPU 节点")
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TG0P"), .gpu)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TB0T"), .battery)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TH0a"), .ssd)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TDVx"), .powerDelivery)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TMVR"), .memory)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "Tm0P"), .memory)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "Ts0P"), .ambient)
    }

    func test_zone_environmentExceptions() {
        // TD 前缀本归供电，但 TDe* 为环境节点 — 例外表优先
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TDeL"), .ambient)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TDER"), .ambient)
    }

    func test_zone_unknownPrefixAndShortKey() {
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "TZ99"), .unknown)
        XCTAssertEqual(ThermalZone.zone(forSensorKey: "T"), .unknown)
    }
}
