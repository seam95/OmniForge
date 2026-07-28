import XCTest
@testable import OmniForge

final class MonitorSamplingPolicyTests: XCTestCase {
    func test_foregroundIntervalMatchesBaseTick() {
        let policy = MonitorSamplingPolicy(baseTick: 2)
        for metric in MonitorMetric.allCases {
            XCTAssertEqual(policy.foregroundInterval(for: metric), 2.0)
        }
    }

    func test_backgroundIntervalVariesByMetric() {
        let policy = MonitorSamplingPolicy(baseTick: 2)
        XCTAssertEqual(policy.backgroundInterval(for: .cpu), 1.0)
        XCTAssertEqual(policy.backgroundInterval(for: .gpu), 10.0)
        XCTAssertEqual(policy.backgroundInterval(for: .disk), 10.0)
        XCTAssertEqual(policy.backgroundInterval(for: .power), 15.0)
        XCTAssertEqual(policy.backgroundInterval(for: .peripheralBattery), 60.0)
    }
}
