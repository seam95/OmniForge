import XCTest
@testable import OmniForge

/// 监控页「温度传感器」卡（无风扇退化形态）热点摘要测试 — SPEC 验收 1–5
final class FanSensorOverviewCardTests: XCTestCase {
    private func sensor(
        _ key: String,
        zone: ThermalZone,
        _ celsius: Double
    ) -> FanSensorReading {
        FanSensorReading(id: key, label: key, zone: zone, temperatureCelsius: celsius)
    }

    /// 构建全量卡模型并取风扇卡（.en 文案：组名 CPU/Power Delivery、分隔符 •）
    private func fanCard(
        sensors: [FanSensorReading] = [],
        fans: [FanReading] = []
    ) -> MonitorCardModel? {
        var snapshot = SystemSnapshot()
        snapshot.sensors = sensors
        snapshot.fans = fans
        return MonitorCardModelBuilder.models(
            snapshot: snapshot,
            configuration: MonitorConfiguration(),
            strings: .en,
            temperatureUnit: .celsius,
            history: MetricHistory()
        ).first { $0.id == .fan }
    }

    func test_fanless_multipleZones_primaryIsPeakAndCaptionListsTopTwoHotspots() throws {
        let card = fanCard(sensors: [
            sensor("Tc0a", zone: .cpu, 78),
            sensor("Tc0b", zone: .cpu, 45),
            sensor("TD0R", zone: .powerDelivery, 61),
            sensor("TB1T", zone: .battery, 33),
        ])

        let fan = try XCTUnwrap(card)
        XCTAssertEqual(fan.primaryText, "78°")
        XCTAssertEqual(fan.secondaryText, "CPU 78° • Power Delivery 61°")
        XCTAssertFalse(fan.hasFanData)
        XCTAssertTrue(fan.hasSensorData)
    }

    func test_fanless_singleZone_captionHasSingleHotspot() throws {
        let card = fanCard(sensors: [sensor("Tc0a", zone: .cpu, 78)])

        let fan = try XCTUnwrap(card)
        XCTAssertEqual(fan.primaryText, "78°")
        XCTAssertEqual(fan.secondaryText, "CPU 78°")
    }

    func test_fanless_unknownSensorsExcludedFromPeakAndCaption() throws {
        let card = fanCard(sensors: [
            sensor("TXYZ", zone: .unknown, 95),
            sensor("Tc0a", zone: .cpu, 78),
        ])

        let fan = try XCTUnwrap(card)
        XCTAssertEqual(fan.primaryText, "78°")
        XCTAssertEqual(fan.secondaryText, "CPU 78°")
    }

    func test_fanless_noSensors_showsPlaceholderWithoutCaption() throws {
        let card = fanCard(sensors: [])

        let fan = try XCTUnwrap(card)
        XCTAssertEqual(fan.primaryText, "--")
        XCTAssertNil(fan.secondaryText)
        XCTAssertFalse(fan.hasSensorData)
    }

    func test_withFans_captionKeepsPerFanRPM() throws {
        let fan0 = FanReading(
            id: 0, currentRPM: 2700, minRPM: 1200, maxRPM: 6500,
            targetRPM: 2700, isManualMode: false
        )
        let card = fanCard(
            sensors: [sensor("Tc0a", zone: .cpu, 78)],
            fans: [fan0]
        )

        let fan = try XCTUnwrap(card)
        XCTAssertTrue(fan.hasFanData)
        XCTAssertEqual(fan.primaryText, "2700 RPM")
        XCTAssertEqual(fan.secondaryText, "2700 RPM")
    }
}
