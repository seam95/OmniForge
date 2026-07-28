import XCTest
@testable import OmniForge

final class GPUUsageSamplerTests: XCTestCase {
    func test_utilizationParsesDeviceUtilizationPercent() {
        XCTAssertEqual(GPUUsageSampler.utilization(from: ["Device Utilization %": 37]), 0.37)
        XCTAssertNil(GPUUsageSampler.utilization(from: [:]))
    }

    func test_sampleDoesNotThrowOnMissingAccelerator() {
        // 真机/模拟环境：至少不应因未 release 崩溃；允许 nil
        let value = try? GPUUsageSampler().sample()
        if let value {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }
}
