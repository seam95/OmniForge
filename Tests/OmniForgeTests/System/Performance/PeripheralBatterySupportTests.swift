import XCTest
@testable import OmniForge

final class PeripheralBatterySupportTests: XCTestCase {
    func test_percentParsesPercentString() {
        XCTAssertEqual(PeripheralBatterySupport.percent(from: "83%"), 83)
        XCTAssertNil(PeripheralBatterySupport.percent(from: "unknown"))
    }

    func test_percentTrimsWhitespace() {
        XCTAssertEqual(PeripheralBatterySupport.percent(from: " 45% "), 45)
    }
}
