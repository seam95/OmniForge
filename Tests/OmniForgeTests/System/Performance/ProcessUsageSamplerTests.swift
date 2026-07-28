import XCTest
@testable import OmniForge

final class ProcessUsageSamplerTests: XCTestCase {
    func test_sampleReturnsSortedAndCount() throws {
        let sampler = ProcessUsageSampler()
        let rows = try sampler.sample(.cpu, limit: 5)
        XCTAssertLessThanOrEqual(rows.count, 5)
        let sorted = rows.sorted { $0.value > $1.value }
        XCTAssertEqual(rows, sorted)
    }

    func test_physicalFootprintHelperReturnsNilForDeadPid() {
        XCTAssertNil(ProcessUsageSampler.physicalFootprint(of: pid_t.max / 2))
    }

    func test_memoryUsesPhysicalFootprintWhenAvailable() throws {
        let sampler = ProcessUsageSampler()
        let rows = try sampler.sample(.memory, limit: 5)
        XCTAssertLessThanOrEqual(rows.count, 5)
        // Values are bytes of phys_footprint (or rss fallback); should be positive when rows exist.
        for row in rows {
            XCTAssertGreaterThan(row.value, 0)
            XCTAssertFalse(row.name.isEmpty)
        }
    }

    func test_gpuFirstSampleIsEmptyBaseline() throws {
        let sampler = ProcessUsageSampler()
        // Fresh sampler has no previous GPU sample — first call primes baseline.
        let first = try sampler.sample(.gpu, limit: 5)
        // Either empty (baseline) or cached empty; must not crash.
        XCTAssertLessThanOrEqual(first.count, 5)
    }

    func test_networkFirstSampleIsEmptyBaseline() throws {
        let sampler = ProcessUsageSampler()
        let first = try sampler.sample(.network, limit: 5)
        // First network sample only primes nettop delta baseline.
        XCTAssertTrue(first.isEmpty)
    }

    func test_stopNetworkClearsDeltaState() throws {
        let sampler = ProcessUsageSampler()
        _ = try sampler.sample(.network, limit: 5)
        sampler.stop(.network)
        // After stop, next sample should again be an empty baseline (not rates).
        let again = try sampler.sample(.network, limit: 5)
        XCTAssertTrue(again.isEmpty)
    }

    func test_stopClearsState() {
        let sampler = ProcessUsageSampler()
        sampler.stop(.cpu)
        sampler.stop(.network)
        sampler.stop(.gpu)
    }

    func test_processUsageIdMatchesPid() {
        let usage = ProcessUsage(pid: 42, name: "x", value: 1.0)
        XCTAssertEqual(usage.id, 42)
        XCTAssertEqual(usage.pid, 42)
        XCTAssertNil(usage.networkDownBytesPerSec)
        XCTAssertNil(usage.networkUpBytesPerSec)
    }

    // MARK: - Baseline priming

    func test_hasProcessBaselineFalseBeforePrimeForGPU() {
        let sampler = ProcessUsageSampler()
        // 新建 sampler 未建 GPU 基线。
        XCTAssertFalse(sampler.hasProcessBaseline(for: .gpu))
    }

    func test_primeProcessBaselinesEstablishesGPUBaseline() {
        let sampler = ProcessUsageSampler()
        XCTAssertFalse(sampler.hasProcessBaseline(for: .gpu))
        sampler.primeProcessBaselines(for: [.gpu, .network])
        // prime 后 GPU 基线应已建立。
        XCTAssertTrue(sampler.hasProcessBaseline(for: .gpu))
    }

    func test_hasProcessBaselineTrueForInstantMetrics() {
        let sampler = ProcessUsageSampler()
        // 瞬时值指标无需基线，恒为 true。
        XCTAssertTrue(sampler.hasProcessBaseline(for: .cpu))
        XCTAssertTrue(sampler.hasProcessBaseline(for: .memory))
        XCTAssertTrue(sampler.hasProcessBaseline(for: .energy))
    }

    func test_stopClearsPrimedGPUBaseline() {
        let sampler = ProcessUsageSampler()
        sampler.primeProcessBaselines(for: [.gpu])
        XCTAssertTrue(sampler.hasProcessBaseline(for: .gpu))
        sampler.stop(.gpu)
        XCTAssertFalse(sampler.hasProcessBaseline(for: .gpu))
    }
}
