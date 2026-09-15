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

    // MARK: - 发现失败退避（审查 R07：失败不得锁定为永久空缓存）

    /// 首轮发现失败 → 退避若干轮 → 恢复后重新发现并锁定（不把临时故障缓存成「无传感器」）。
    func test_discoveryFailure_retriesWithBackoffAndRecovers() throws {
        let mock = makeMock(keys: ["Tp01"], values: ["Tp01": 45])
        mock.suppressKeyEnumeration = true
        let catalog = TemperatureSensorCatalog(smc: mock)

        // 首轮失败：返回空但未锁定。
        XCTAssertTrue(try catalog.sampleSensors().isEmpty, "发现失败本轮无读数")

        // 退避窗口（1 轮）内跳过发现；窗口过后 SMC 恢复 → 重新发现成功。
        mock.suppressKeyEnumeration = false
        XCTAssertTrue(try catalog.sampleSensors().isEmpty, "退避窗口内不重试发现")
        let sensors = try catalog.sampleSensors()
        XCTAssertEqual(sensors.map(\.id), ["Tp01"], "窗口过后恢复发现，不残留空缓存")
    }

    /// 连续失败后退避指数增长（1、2、4…轮），恢复后重新发现成功。
    func test_discoveryFailure_backoffGrowsExponentially() throws {
        let mock = makeMock(keys: ["Tp01"], values: ["Tp01": 45])
        mock.suppressKeyEnumeration = true
        let catalog = TemperatureSensorCatalog(smc: mock)

        // 失败 #1 → 退避 1 轮。
        _ = try catalog.sampleSensors()
        _ = try catalog.sampleSensors()  // 退避窗口内跳过
        // 失败 #2 → 退避 2 轮。
        _ = try catalog.sampleSensors()
        _ = try catalog.sampleSensors()  // 窗口内
        _ = try catalog.sampleSensors()  // 窗口内
        // 失败 #3 → 退避 4 轮（SMC 恢复后窗口走完即重新发现成功）。
        _ = try catalog.sampleSensors()
        mock.suppressKeyEnumeration = false
        _ = try catalog.sampleSensors()  // 窗口内
        _ = try catalog.sampleSensors()  // 窗口内
        _ = try catalog.sampleSensors()  // 窗口内
        _ = try catalog.sampleSensors()  // 窗口内
        let sensors = try catalog.sampleSensors()  // 重试 → 成功锁定
        XCTAssertEqual(sensors.map(\.id), ["Tp01"])
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
