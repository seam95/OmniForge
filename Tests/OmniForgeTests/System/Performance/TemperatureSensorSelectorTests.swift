import XCTest
@testable import OmniForge

// MARK: - Mock

final class MockSMCReading: SMCReading {
    private let storage: [String: Double]

    init(_ values: [String: Double]) {
        self.storage = values
    }

    func value(forKey key: String) -> Double? {
        storage[key]
    }
}

final class TemperatureSensorSelectorTests: XCTestCase {
    // MARK: - Platform detection

    func test_currentPlatformReturnsValue() {
        let platform = TemperatureSensorSelector.currentPlatform()
        XCTAssertNotNil(platform)
    }

    func test_platformParsesAppleSiliconBrandStrings() {
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: "Apple M1"), .appleM1Family)
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: "Apple M2 Pro"), .appleM2Family)
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: "Apple M3 Max"), .appleM3Family)
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: "Apple M4"), .appleM4Family)
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: "Apple M5"), .appleM5Family)
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: "Intel(R) Core"), .generic)
        XCTAssertEqual(TemperatureSensorSelector.platform(brandString: nil), .generic)
    }

    // MARK: - Core key recognition

    func test_m4CoreKeysRecognized() {
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Te05", platform: .appleM4Family))
        XCTAssertFalse(TemperatureSensorSelector.isCPUCoreKey("TG0P", platform: .appleM4Family))
    }

    func test_m1CoreKeysRecognized() {
        // 旧键仍识别
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Tp09", platform: .appleM1Family))
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Tp0T", platform: .appleM1Family))
        // 现代 M1 固件键（实测存在）
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Tc0a", platform: .appleM1Family))
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Tp2a", platform: .appleM1Family))
        XCTAssertFalse(TemperatureSensorSelector.isCPUCoreKey("Te05", platform: .appleM1Family))
    }

    func test_cpuTemperatureReadsModernM1Keys() {
        // 旧 Tp0* 全无读时，应能读到现代 Tc*/Tp2* 键
        let smc = MockSMCReading([
            "Tc0a": 65.5,
            "Tc0b": 66.0,
            "Tp2a": 70.0,
            "TB0T": 37.0
        ])
        let temp = TemperatureSensorSelector.cpuTemperature(from: smc, platform: .appleM1Family)
        XCTAssertEqual(temp, 70.0)
    }

    func test_gpuTemperatureReadsModernAppleSiliconKeys() {
        let smc = MockSMCReading([
            "TG0P": 0, // 旧键缺失/无效
            "Tg1b": 69.3,
            "tGMD": 71.0
        ])
        let temp = TemperatureSensorSelector.gpuTemperature(from: smc)
        XCTAssertEqual(temp, 71.0)
    }

    func test_m3CoreKeysRecognized() {
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Te0S", platform: .appleM3Family))
        XCTAssertTrue(TemperatureSensorSelector.isCPUCoreKey("Tf04", platform: .appleM3Family))
        XCTAssertFalse(TemperatureSensorSelector.isCPUCoreKey("Tp09", platform: .appleM3Family))
    }

    func test_genericHasNoCoreKeys() {
        XCTAssertFalse(TemperatureSensorSelector.isCPUCoreKey("Tp09", platform: .generic))
        XCTAssertFalse(TemperatureSensorSelector.hasCPUCoreSet(platform: .generic))
        XCTAssertTrue(TemperatureSensorSelector.hasCPUCoreSet(platform: .appleM4Family))
    }

    // MARK: - displayedCPUTemperature

    func test_displayedCPUTemperaturePrefersCoreMax() {
        let readings: [(key: String, value: Double)] = [
            ("Te05", 41),
            ("Tp01", 55), // Tp01 is not in M3 core set
            ("Te0S", 60)
        ]
        let value = TemperatureSensorSelector.displayedCPUTemperature(
            readings: readings, platform: .appleM3Family
        )
        XCTAssertEqual(value, 60)
    }

    func test_displayedCPUTemperatureFallsBackToMaxWhenNoCoreHits() {
        let readings: [(key: String, value: Double)] = [
            ("Tp01", 55),
            ("TG0P", 40),
            ("unknown", 48)
        ]
        let value = TemperatureSensorSelector.displayedCPUTemperature(
            readings: readings, platform: .appleM3Family
        )
        XCTAssertEqual(value, 55)
    }

    func test_displayedCPUTemperatureSkipsImplausibleValues() {
        let readings: [(key: String, value: Double)] = [
            ("Te05", 0),
            ("Te0S", 200),
            ("Te0P", 42)
        ]
        let value = TemperatureSensorSelector.displayedCPUTemperature(
            readings: readings, platform: .appleM3Family
        )
        XCTAssertEqual(value, 42)
    }

    func test_displayedCPUTemperatureReturnsNilWhenEmpty() {
        XCTAssertNil(
            TemperatureSensorSelector.displayedCPUTemperature(readings: [], platform: .appleM1Family)
        )
    }

    // MARK: - Compatibility wrappers (no first-key-wins across channels)

    func test_cpuTemperatureUsesPlatformCoreSelection() {
        // On M4, Te05 is core; TG0P is GPU and must not be selected via CPU path
        let smc = MockSMCReading(["Te05": 47.0, "TG0P": 90.0, "TB0T": 30.0])
        let temp = TemperatureSensorSelector.cpuTemperature(from: smc, platform: .appleM4Family)
        XCTAssertEqual(temp, 47.0)
    }

    func test_cpuTemperatureReturnsMaxOfCoreKeys() {
        let smc = MockSMCReading(["Te05": 41.0, "Te0S": 60.0, "Tp01": 99.0])
        let temp = TemperatureSensorSelector.cpuTemperature(from: smc, platform: .appleM3Family)
        XCTAssertEqual(temp, 60.0)
    }

    func test_cpuTemperatureSkipsOutOfRangeValues() {
        let smc = MockSMCReading(["Tp09": 0])
        let temp = TemperatureSensorSelector.cpuTemperature(from: smc, platform: .appleM1Family)
        XCTAssertNil(temp)
    }

    func test_cpuTemperatureReturnsNilWhenNoKeysPresent() {
        let smc = MockSMCReading([:])
        let temp = TemperatureSensorSelector.cpuTemperature(from: smc)
        XCTAssertNil(temp)
    }

    // MARK: - GPU temperature (max, not first)

    func test_gpuTemperatureReturnsMaxValid() {
        let smc = MockSMCReading(["TG0p": 38.2, "TG0P": 45.0, "TG1P": 0])
        let temp = TemperatureSensorSelector.gpuTemperature(from: smc)
        XCTAssertEqual(temp, 45.0)
    }

    func test_gpuTemperatureReturnsNilWhenNoKeysPresent() {
        let smc = MockSMCReading([:])
        let temp = TemperatureSensorSelector.gpuTemperature(from: smc)
        XCTAssertNil(temp)
    }

    // MARK: - Battery temperature (max, not first)

    func test_batteryTemperatureReturnsMaxValid() {
        let smc = MockSMCReading(["TB0T": 28.1, "TB1T": 31.5])
        let temp = TemperatureSensorSelector.batteryTemperature(from: smc)
        XCTAssertEqual(temp, 31.5)
    }

    func test_batteryTemperatureReturnsNilWhenNoKeysPresent() {
        let smc = MockSMCReading([:])
        let temp = TemperatureSensorSelector.batteryTemperature(from: smc)
        XCTAssertNil(temp)
    }
}
