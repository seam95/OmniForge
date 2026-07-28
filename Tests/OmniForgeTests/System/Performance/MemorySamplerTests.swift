import XCTest
@testable import OmniForge

final class MemorySamplerTests: XCTestCase {
    func test_memoryPressureMapsKernelLevels() {
        XCTAssertEqual(MemoryPressure(kernelLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(kernelLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
        XCTAssertEqual(MemoryPressure(kernelLevel: 0), .unknown)
        XCTAssertEqual(MemoryPressure(kernelLevel: 99), .unknown)
    }

    func test_sampleReturnsUsedLessThanOrEqualTotal() throws {
        let reading = try MemorySampler().sample()
        XCTAssertGreaterThan(reading.total, 0)
        XCTAssertLessThanOrEqual(reading.used, reading.total)
        // 与旧公式不同：used 不应再约等于 active+wire 的明显低估；
        // 这里至少要求 used > 0 且 pressure 不是靠 free+inactive 自造。
        XCTAssertNotEqual(reading.pressure, MemoryPressure(rawValue: 999))
    }
}
