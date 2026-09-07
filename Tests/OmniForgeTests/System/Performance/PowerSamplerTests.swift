import XCTest
import OmniForgeSMC
@testable import OmniForge

// MARK: - Mocks

private final class MockMaxCapacityProbe: MaxCapacityProbing {
    var percent: Int?
    private(set) var refreshCallCount = 0

    init(percent: Int? = nil) {
        self.percent = percent
    }

    func refreshIfStale() {
        refreshCallCount += 1
    }
}

final class PowerSamplerTests: XCTestCase {
    func test_timeRemainingOnlyExistsWhileDischarging() {
        XCTAssertEqual(BatteryTimeSupport.remainingSeconds(timeToEmptyMinutes: 120,
                                                           externalConnected: false,
                                                           isCharging: false), 7_200)
        XCTAssertNil(BatteryTimeSupport.remainingSeconds(timeToEmptyMinutes: 120,
                                                         externalConnected: true,
                                                         isCharging: true))
    }

    func test_powerReadingSupportsSystemWattsField() {
        var reading = PowerReading()
        reading.systemWatts = 12.5
        XCTAssertEqual(reading.systemWatts, 12.5)
    }

    func test_powerReadingSupportsAdapterWattsField() {
        var reading = PowerReading()
        reading.adapterWatts = 45.0
        XCTAssertEqual(reading.adapterWatts, 45.0)
    }

    func test_maxCapacityProbeRefreshUpdatesPercent() {
        let probe = MaxCapacityProbe()
        probe.refreshIfStale()
        // Machines with a battery should report 0...100; desktops may stay nil.
        if let percent = probe.percent {
            XCTAssertGreaterThanOrEqual(percent, 0)
            XCTAssertLessThanOrEqual(percent, 100)
        }
    }

    func test_sample_readsSystemWattsFromPSTR() throws {
        let smc = MockSMCReading(["PSTR": 18.4, "PDTR": 40.0])
        let sampler = PowerSampler(smc: smc, maxCapacityProbe: MockMaxCapacityProbe())
        let reading = try sampler.sample()
        XCTAssertEqual(reading.systemWatts, 18.4)
        XCTAssertEqual(reading.adapterWatts, 40.0)
    }

    func test_sample_fallsBackToPDTRForSystemWhenPSTRMissing() throws {
        let smc = MockSMCReading(["PDTR": 22.5])
        let sampler = PowerSampler(smc: smc, maxCapacityProbe: MockMaxCapacityProbe())
        let reading = try sampler.sample()
        XCTAssertEqual(reading.systemWatts, 22.5)
        XCTAssertEqual(reading.adapterWatts, 22.5)
    }

    func test_sample_rejectsImplausibleAdapterWatts() throws {
        let smc = MockSMCReading(["PSTR": 0, "PDTR": 1500])
        let sampler = PowerSampler(smc: smc, maxCapacityProbe: MockMaxCapacityProbe())
        let reading = try sampler.sample()
        XCTAssertNil(reading.adapterWatts)
    }

    func test_sample_prefersPSTROverPDTRForSystem() throws {
        let smc = MockSMCReading(["PSTR": 15.0, "PDTR": 50.0])
        let sampler = PowerSampler(smc: smc, maxCapacityProbe: MockMaxCapacityProbe())
        let reading = try sampler.sample()
        XCTAssertEqual(reading.systemWatts, 15.0)
        XCTAssertEqual(reading.adapterWatts, 50.0)
    }

    func test_healthPercent_prefersNominalChargeOverDesignCapacity() {
        // 锚点取自实测机型：NominalChargeCapacity 3666 / DesignCapacity 4382，
        // 与系统信息「最大容量 83%」口径一致。
        let props: [String: Any] = ["DesignCapacity": 4382, "NominalChargeCapacity": 3666]
        XCTAssertEqual(PowerSampler.healthPercent(fromBatteryProperties: props) ?? 0, 83.66, accuracy: 0.01)
    }

    func test_healthPercent_fallsThroughFullChargeCandidates() {
        let design = 4382
        let onlyRaw: [String: Any] = ["DesignCapacity": design, "AppleRawMaxCapacity": 3536]
        XCTAssertEqual(PowerSampler.healthPercent(fromBatteryProperties: onlyRaw) ?? 0, 80.69, accuracy: 0.01)

        let fullChargeWins: [String: Any] = ["DesignCapacity": design,
                                             "FullChargeCapacity": 4000,
                                             "AppleRawMaxCapacity": 3536]
        XCTAssertEqual(PowerSampler.healthPercent(fromBatteryProperties: fullChargeWins) ?? 0, 91.28, accuracy: 0.01)
    }

    func test_healthPercent_capsAt100AndReturnsNilWhenIncomplete() {
        XCTAssertEqual(PowerSampler.healthPercent(fromBatteryProperties: [
            "DesignCapacity": 4000, "NominalChargeCapacity": 4100
        ]), 100)
        XCTAssertNil(PowerSampler.healthPercent(fromBatteryProperties: ["NominalChargeCapacity": 3666]))
        XCTAssertNil(PowerSampler.healthPercent(fromBatteryProperties: [:]))
    }

    func test_sample_healthDoesNotConsultProbeWhenRegistryRatioAvailable() throws {
        let probe = MockMaxCapacityProbe(percent: 87)
        let sampler = PowerSampler(smc: MockSMCReading([:]), maxCapacityProbe: probe)
        let reading = try sampler.sample()
        // IORegistry 比值可用时不再咨询 probe，避免部分机型 IOPS 恒报 100 覆盖真实健康度。
        if reading.hasBattery, reading.healthPercent != nil {
            XCTAssertEqual(probe.refreshCallCount, 0)
        }
    }
}
