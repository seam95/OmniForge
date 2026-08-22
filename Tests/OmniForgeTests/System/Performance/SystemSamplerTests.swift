import XCTest
@testable import OmniForge

final class SystemSamplerTests: XCTestCase {
    // MARK: - CPU Delta

    func test_cpuDeltaUsesBusyShareBetweenSamples() {
        // deltaUser=30, deltaSystem=10, deltaNice=10, deltaTotal=100
        // total = 50/100 = 0.5；user = 30/100 = 0.3；system = (10+10)/100 = 0.2
        let result = CPUUsageSampler.reading(
            previousUser: 10, previousSystem: 5, previousNice: 5, previousTotal: 100,
            user: 40, system: 15, nice: 15, total: 200
        )
        XCTAssertEqual(result?.total ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result?.user ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result?.system ?? 0, 0.2, accuracy: 0.0001)
    }

    func test_cpuReadingUserPlusSystemEqualsTotal() {
        // nice 并入系统：user + system == total
        let result = CPUUsageSampler.reading(
            previousUser: 0, previousSystem: 0, previousNice: 0, previousTotal: 0,
            user: 40, system: 15, nice: 15, total: 100
        )
        XCTAssertEqual(
            (result?.user ?? 0) + (result?.system ?? 0),
            result?.total ?? 0,
            accuracy: 0.0001
        )
    }

    func test_cpuCounterResetReturnsNil() {
        let result = CPUUsageSampler.reading(
            previousUser: 10, previousSystem: 5, previousNice: 5, previousTotal: 200,
            user: 5, system: 2, nice: 1, total: 100
        )
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
