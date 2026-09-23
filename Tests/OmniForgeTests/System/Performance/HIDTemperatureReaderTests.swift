import XCTest
@testable import OmniForge

final class HIDTemperatureReaderTests: XCTestCase {
    func test_hidReader_conformsToProtocol() {
        let reader: HIDTemperatureReading = HIDTemperatureReader.shared
        XCTAssertNotNil(reader)
    }

    func test_hidReader_onAppleSilicon_returnsPlausibleOrNil() {
        let reader = HIDTemperatureReader.shared
        if let cpu = reader.sampleCPU() {
            XCTAssertGreaterThan(cpu, 1.0)
            XCTAssertLessThan(cpu, 125.0)
        }
        if let gpu = reader.sampleGPU() {
            XCTAssertGreaterThan(gpu, 1.0)
            XCTAssertLessThan(gpu, 125.0)
        }
        if let bat = reader.sampleBattery() {
            XCTAssertGreaterThan(bat, 1.0)
            XCTAssertLessThan(bat, 125.0)
        }
    }
}
