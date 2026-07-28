import XCTest
@testable import OmniForge

final class SystemSamplerTests: XCTestCase {
    // MARK: - CPU Delta

    func test_cpuDeltaUsesBusyShareBetweenSamples() {
        let result = CPUUsageSampler.usage(previousBusy: 20, previousTotal: 100,
                                           busy: 50, total: 200)
        XCTAssertEqual(result ?? 0, 0.3, accuracy: 0.0001)
    }

    func test_cpuCounterResetReturnsNil() {
        let result = CPUUsageSampler.usage(previousBusy: 50, previousTotal: 200,
                                           busy: 10, total: 100)
        XCTAssertNil(result)
    }

    // MARK: - GPU Utilization

    func test_gpuUtilizationRequiresPublishedInteger() {
        XCTAssertEqual(GPUUsageSampler.utilization(from: ["Device Utilization %": 45]), 0.45)
        XCTAssertNil(GPUUsageSampler.utilization(from: [:]))
    }

    // MARK: - Memory

    func test_memoryReadsHostStatistics() throws {
        let sampler = MemorySampler()
        let reading = try sampler.sample()
        XCTAssertGreaterThan(reading.total, 0)
        XCTAssertGreaterThan(reading.total, reading.used)
    }

    // MARK: - Samplers handle failure propagation

    func test_samplerConstructorsDoNotThrow() {
        XCTAssertNoThrow(CPUUsageSampler())
        XCTAssertNoThrow(GPUUsageSampler())
        XCTAssertNoThrow(MemorySampler())
        XCTAssertNoThrow(TemperatureSampler(smc: SMCClient()))
    }
}
