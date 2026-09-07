import XCTest
@testable import OmniForge

/// FanSensorGroupSummary 纯函数测试 — 分组/unknown 过滤/降序/最高值/边界
final class FanSensorGroupSummaryTests: XCTestCase {
    private func sensor(
        _ key: String,
        zone: ThermalZone,
        _ celsius: Double,
        label: String? = nil
    ) -> FanSensorReading {
        FanSensorReading(
            id: key,
            label: label ?? key,
            zone: zone,
            temperatureCelsius: celsius
        )
    }

    // MARK: - 分组与顺序

    func test_summaries_groupsByZoneInCanonicalOrder() {
        let readings = [
            sensor("TB1T", zone: .battery, 33),
            sensor("Tc0a", zone: .cpu, 45),
            sensor("TA0P", zone: .ambient, 28),
        ]

        let summaries = FanSensorGroupSummary.summaries(from: readings)

        XCTAssertEqual(summaries.map(\.zone), [.cpu, .battery, .ambient])
        XCTAssertEqual(summaries[0].sensors.map(\.id), ["Tc0a"])
    }

    func test_summaries_emptyInputYieldsNoSummaries() {
        XCTAssertTrue(FanSensorGroupSummary.summaries(from: []).isEmpty)
    }

    // MARK: - unknown 过滤

    func test_summaries_hidesUnknownZoneByDefault() {
        let readings = [
            sensor("Tc0a", zone: .cpu, 45),
            sensor("TXYZ", zone: .unknown, 50),
        ]

        let summaries = FanSensorGroupSummary.summaries(from: readings)

        XCTAssertEqual(summaries.map(\.zone), [.cpu])
        XCTAssertEqual(FanSensorGroupSummary.hiddenUnknownCount(from: readings), 1)
    }

    func test_summaries_keepsUnknownZoneWhenNotHiding() {
        let readings = [sensor("TXYZ", zone: .unknown, 50)]

        let summaries = FanSensorGroupSummary.summaries(from: readings, hidingUnknown: false)

        XCTAssertEqual(summaries.map(\.zone), [.unknown])
    }

    func test_hiddenUnknownCount_zeroWhenAllCategorized() {
        let readings = [sensor("Tc0a", zone: .cpu, 45)]

        XCTAssertEqual(FanSensorGroupSummary.hiddenUnknownCount(from: readings), 0)
    }

    // MARK: - 组内排序与最高值

    func test_summaries_sortsSensorsByTemperatureDescending() {
        let readings = [
            sensor("Tc0a", zone: .cpu, 45),
            sensor("Tc0b", zone: .cpu, 78),
            sensor("Tc0c", zone: .cpu, 61),
        ]

        let summaries = FanSensorGroupSummary.summaries(from: readings)

        XCTAssertEqual(summaries[0].sensors.map(\.temperatureCelsius), [78, 61, 45])
        XCTAssertEqual(summaries[0].hottest?.id, "Tc0b")
    }

    func test_summaries_tieKeepsDiscoveryOrder() {
        // 稳定排序：并列温度时保持传入序（与采样发现序一致）
        let readings = [
            sensor("Tc0a", zone: .cpu, 45),
            sensor("Tc0b", zone: .cpu, 45),
        ]

        let summaries = FanSensorGroupSummary.summaries(from: readings)

        XCTAssertEqual(summaries[0].sensors.map(\.id), ["Tc0a", "Tc0b"])
        XCTAssertEqual(summaries[0].hottest?.id, "Tc0a")
    }

    func test_summaries_singleSensorGroupKeepsHottest() {
        let readings = [sensor("TB1T", zone: .battery, 33, label: "电池")]

        let summaries = FanSensorGroupSummary.summaries(from: readings)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].sensors.count, 1)
        XCTAssertEqual(summaries[0].hottest?.label, "电池")
    }
}
