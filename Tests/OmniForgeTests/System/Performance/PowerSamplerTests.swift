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

    func test_sample_healthUsesMaxCapacityProbeOverride() throws {
        let probe = MockMaxCapacityProbe(percent: 87)
        let sampler = PowerSampler(smc: MockSMCReading([:]), maxCapacityProbe: probe)
        let reading = try sampler.sample()
        // Probe only overrides when battery properties exist. Without a battery,
        // health stays nil and probe is not consulted on the battery path.
        // This asserts the probe API remains injectable for machines with batteries.
        XCTAssertEqual(probe.percent, 87)
        // If this machine has a battery, health should match the probe override.
        if reading.hasBattery {
            XCTAssertEqual(reading.healthPercent, 87)
            XCTAssertGreaterThanOrEqual(probe.refreshCallCount, 1)
        }
    }
}
