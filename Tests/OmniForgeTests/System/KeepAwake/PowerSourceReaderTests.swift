import XCTest
@testable import OmniForge

final class FakePowerSourceProvider: KeepAwakePowerSourceProviding {
    var dictionaries: [[String: Any]]?
    func copyPowerSourceDictionaries() -> [[String: Any]]? { dictionaries }
}

final class PowerSourceReaderTests: XCTestCase {
    func test_batteryOnBattery_andAC_andNoBattery() throws {
        let provider = FakePowerSourceProvider()
        let reader = PowerSourceReader(provider: provider)

        provider.dictionaries = [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String,
            kIOPSCurrentCapacityKey as String: 55,
            kIOPSMaxCapacityKey as String: 100,
        ]]
        let onBattery = try reader.read()
        XCTAssertTrue(onBattery.hasBattery)
        XCTAssertTrue(onBattery.isOnBattery)
        XCTAssertEqual(onBattery.percentage, 55)

        provider.dictionaries = [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSPowerSourceStateKey as String: kIOPSACPowerValue as String,
            kIOPSCurrentCapacityKey as String: 100,
            kIOPSMaxCapacityKey as String: 100,
        ]]
        let onAC = try reader.read()
        XCTAssertTrue(onAC.hasBattery)
        XCTAssertFalse(onAC.isOnBattery)
        XCTAssertEqual(onAC.percentage, 100)

        provider.dictionaries = []
        let none = try reader.read()
        XCTAssertFalse(none.hasBattery)
        XCTAssertFalse(none.isOnBattery)
        XCTAssertNil(none.percentage)
    }

    func test_percentageZeroAndInvalidRawValues() throws {
        let provider = FakePowerSourceProvider()
        let reader = PowerSourceReader(provider: provider)

        provider.dictionaries = [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String,
            kIOPSCurrentCapacityKey as String: 0,
            kIOPSMaxCapacityKey as String: 100,
        ]]
        XCTAssertEqual(try reader.read().percentage, 0)

        provider.dictionaries = [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String,
            kIOPSCurrentCapacityKey as String: "bad",
            kIOPSMaxCapacityKey as String: 100,
        ]]
        XCTAssertThrowsError(try reader.read())
    }

    func test_systemAPIFailure_andMissingFields() {
        let provider = FakePowerSourceProvider()
        let reader = PowerSourceReader(provider: provider)

        provider.dictionaries = nil
        XCTAssertThrowsError(try reader.read()) { error in
            guard case let KeepAwakeError.batteryReadFailed(message) = error as! KeepAwakeError else {
                return XCTFail("expected batteryReadFailed")
            }
            XCTAssertFalse(message.isEmpty)
        }

        provider.dictionaries = [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String,
        ]]
        XCTAssertThrowsError(try reader.read())
    }

    func test_lowBatteryTriggerRules() {
        let onBatteryLow = KeepAwakePowerSnapshot(hasBattery: true, isOnBattery: true, percentage: 10)
        let onBatteryEqual = KeepAwakePowerSnapshot(hasBattery: true, isOnBattery: true, percentage: 10)
        let onAC = KeepAwakePowerSnapshot(hasBattery: true, isOnBattery: false, percentage: 5)
        let noBattery = KeepAwakePowerSnapshot(hasBattery: false, isOnBattery: false, percentage: nil)

        XCTAssertTrue(PowerSourceReader.shouldEndForLowBattery(snapshot: onBatteryLow, limit: .percent10))
        XCTAssertTrue(PowerSourceReader.shouldEndForLowBattery(snapshot: onBatteryEqual, limit: .percent10))
        XCTAssertFalse(PowerSourceReader.shouldEndForLowBattery(snapshot: onAC, limit: .percent10))
        XCTAssertFalse(PowerSourceReader.shouldEndForLowBattery(snapshot: noBattery, limit: .percent10))
        XCTAssertFalse(PowerSourceReader.shouldEndForLowBattery(snapshot: onBatteryLow, limit: .disabled))
    }
}
