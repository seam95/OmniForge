import XCTest
@testable import OmniForge

final class MetricFormatTests: XCTestCase {
    func test_percentWithNilReturnsNil() {
        XCTAssertNil(MetricFormat.percent(nil))
    }

    func test_percentFormatsCorrectly() {
        XCTAssertEqual(MetricFormat.percent(0.5), "50%")
        XCTAssertEqual(MetricFormat.percent(1.0), "100%")
        XCTAssertEqual(MetricFormat.percent(0.0), "0%")
    }

    func test_bytesPerSecWithNilReturnsNil() {
        XCTAssertNil(MetricFormat.bytesPerSec(nil))
    }

    func test_bytesPerSecFormats() {
        XCTAssertEqual(MetricFormat.bytesPerSec(500), "500 B/s")
        XCTAssertEqual(MetricFormat.bytesPerSec(1_500), "1.5 KB/s")
        XCTAssertEqual(MetricFormat.bytesPerSec(1_500_000), "1.4 MB/s")
        XCTAssertEqual(MetricFormat.bytesPerSec(1_500_000_000), "1.4 GB/s")
    }

    func test_bytesUses1024Base() {
        XCTAssertEqual(MetricFormat.bytes(1_024), "1.0 KB")
        XCTAssertEqual(MetricFormat.bytes(1_048_576), "1.0 MB")
    }

    func test_bytesPerSecUses1024Base() {
        XCTAssertEqual(MetricFormat.bytesPerSec(1_024), "1.0 KB/s")
    }

    func test_diskBytesUses1000Base() {
        XCTAssertEqual(MetricFormat.diskBytes(1_000), "1.0 KB")
        XCTAssertEqual(MetricFormat.diskBytes(1_000_000_000), "1.0 GB")
    }

    func test_memoryUsedMatchesActivityMonitorFormula() {
        // total 8 GiB, page 16 KiB, free=1000, speculative=100, external=900
        // available = 2000 * 16384 = 32_768_000
        // used = 8_589_934_592 - 32_768_000
        let used = MetricFormat.memoryUsed(
            totalBytes: 8_589_934_592,
            pageSize: 16_384,
            freePages: 1_000,
            speculativePages: 100,
            fileBackedPages: 900
        )
        XCTAssertEqual(used, 8_589_934_592 - 32_768_000)
    }

    func test_memoryUsedClampsWhenAvailableExceedsTotal() {
        let used = MetricFormat.memoryUsed(
            totalBytes: 1_000,
            pageSize: 4_096,
            freePages: 10,
            speculativePages: 10,
            fileBackedPages: 10
        )
        XCTAssertEqual(used, 0)
    }

    func test_stabilizedGPUUsageLimitsUpSpike() {
        let next = MetricFormat.stabilizedGPUUsage(previous: 0.10, current: 0.90)
        XCTAssertEqual(next, 0.30, accuracy: 0.0001) // +0.20 cap
    }

    func test_stabilizedGPUUsageSmoothsDown() {
        let next = MetricFormat.stabilizedGPUUsage(previous: 0.80, current: 0.20)
        XCTAssertEqual(next, 0.80 * 0.35 + 0.20 * 0.65, accuracy: 0.0001)
    }

    func test_stabilizedGPUUsageFirstSampleClampsCurrent() {
        // 无前值时返回 clamp 后的当前值，不伪造
        XCTAssertEqual(MetricFormat.stabilizedGPUUsage(previous: nil, current: 0.5), 0.5, accuracy: 0.0001)
        // 超界值被 clamp 到 [0, 1]
        XCTAssertEqual(MetricFormat.stabilizedGPUUsage(previous: nil, current: 1.5), 1.0, accuracy: 0.0001)
    }

    func test_stabilizedGPUUsageNonFiniteCurrentReturnsZero() {
        // NaN / Inf 不应产生伪造读数
        XCTAssertEqual(MetricFormat.stabilizedGPUUsage(previous: nil, current: .nan), 0, accuracy: 0.0001)
        XCTAssertEqual(MetricFormat.stabilizedGPUUsage(previous: nil, current: .infinity), 0, accuracy: 0.0001)
    }

    func test_celsiusWithNilReturnsNil() {
        XCTAssertNil(MetricFormat.celsius(nil))
    }

    func test_celsiusFormats() {
        XCTAssertEqual(MetricFormat.celsius(72.5), "72°")
        XCTAssertEqual(MetricFormat.celsius(0), "0°")
    }

    func test_fahrenheitFormats() {
        XCTAssertEqual(MetricFormat.fahrenheit(100), "212°F")
    }

    func test_memoryWithNilReturnsNil() {
        XCTAssertNil(MetricFormat.memory(nil, total: 100))
        XCTAssertNil(MetricFormat.memory(50, total: nil))
    }

    func test_memoryFormats() {
        XCTAssertEqual(MetricFormat.memory(25, total: 100), "25%")
    }

    func test_shortMemoryFormats() {
        let result = MetricFormat.shortMemory(500_000_000, total: 8_000_000_000)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("/"))
    }

    func test_temperatureWithUnit() {
        let c = MetricFormat.temperature(100, unit: .celsius)
        XCTAssertEqual(c, "100°")
        let f = MetricFormat.temperature(100, unit: .fahrenheit)
        XCTAssertEqual(f, "212°F")
    }

    func test_temperatureWithNilReturnsNil() {
        XCTAssertNil(MetricFormat.temperature(nil, unit: .celsius))
    }
}
