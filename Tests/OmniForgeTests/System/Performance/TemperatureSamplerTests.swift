import XCTest
import OmniForgeSMC
@testable import OmniForge

final class TemperatureSamplerTests: XCTestCase {
    func test_temperatureSamplerReturnsIndependentChannels() throws {
        let smc = MockSMCReading([
            "Tp09": 50,
            "TG0P": 40,
            "TB0T": 30
        ])
        let sampler = TemperatureSampler(smc: smc, platform: .appleM1Family)
        XCTAssertEqual(try sampler.sampleCPU(), 50)
        XCTAssertEqual(try sampler.sampleGPU(), 40)
        XCTAssertEqual(try sampler.sampleBattery(), 30)
    }

    func test_sampleCPUPrefersCoreKeysOverFallback() throws {
        let smc = MockSMCReading([
            "Te05": 41,
            "Tp01": 55, // not M3 core
            "Te0S": 60
        ])
        let sampler = TemperatureSampler(smc: smc, platform: .appleM3Family)
        XCTAssertEqual(try sampler.sampleCPU(), 60)
    }

    func test_sampleGPUUsesMaxNotFirstKey() throws {
        let smc = MockSMCReading([
            "TG0p": 30,
            "TG0P": 48
        ])
        let sampler = TemperatureSampler(smc: smc, platform: .generic)
        XCTAssertEqual(try sampler.sampleGPU(), 48)
    }

    func test_sampleBatteryUsesMaxNotFirstKey() throws {
        let smc = MockSMCReading([
            "TB0T": 25,
            "TB2T": 33
        ])
        let sampler = TemperatureSampler(smc: smc, platform: .generic)
        XCTAssertEqual(try sampler.sampleBattery(), 33)
    }

    func test_channelsDoNotCrossBleed() throws {
        // Only GPU present: CPU/battery stay nil, GPU returns independently
        let smc = MockSMCReading(["TG0P": 44])
        let sampler = TemperatureSampler(smc: smc, platform: .appleM4Family)
        XCTAssertNil(try sampler.sampleCPU())
        XCTAssertEqual(try sampler.sampleGPU(), 44)
        XCTAssertNil(try sampler.sampleBattery())
    }

    func test_emptySMCReturnsNilPerChannel() throws {
        let sampler = TemperatureSampler(smc: MockSMCReading([:]), platform: .generic)
        XCTAssertNil(try sampler.sampleCPU())
        XCTAssertNil(try sampler.sampleGPU())
        XCTAssertNil(try sampler.sampleBattery())
    }

    func test_samplePrefersHIDOverSMCWhenAvailable() throws {
        let hid = MockHIDTemperatureReader(cpu: 68.5, gpu: 52.0, battery: 36.0)
        let smc = MockSMCReading([
            "Tp09": 50,
            "TG0P": 40,
            "TB0T": 30
        ])
        let sampler = TemperatureSampler(smc: smc, hidReader: hid, platform: .appleM1Family)
        XCTAssertEqual(try sampler.sampleCPU(), 68.5)
        XCTAssertEqual(try sampler.sampleGPU(), 52.0)
        XCTAssertEqual(try sampler.sampleBattery(), 36.0)
    }

    func test_sampleFallsBackToSMCWhenHIDReturnsNil() throws {
        let hid = MockHIDTemperatureReader(cpu: nil, gpu: nil, battery: nil)
        let smc = MockSMCReading([
            "Tp09": 50,
            "TG0P": 40,
            "TB0T": 30
        ])
        let sampler = TemperatureSampler(smc: smc, hidReader: hid, platform: .appleM1Family)
        XCTAssertEqual(try sampler.sampleCPU(), 50)
        XCTAssertEqual(try sampler.sampleGPU(), 40)
        XCTAssertEqual(try sampler.sampleBattery(), 30)
    }
}

private final class MockHIDTemperatureReader: HIDTemperatureReading {
    var cpu: Double?
    var gpu: Double?
    var battery: Double?

    init(cpu: Double? = nil, gpu: Double? = nil, battery: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
    }

    func sampleCPU() -> Double? { cpu }
    func sampleGPU() -> Double? { gpu }
    func sampleBattery() -> Double? { battery }
}
