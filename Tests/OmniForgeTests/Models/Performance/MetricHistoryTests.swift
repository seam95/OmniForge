import XCTest
@testable import OmniForge

final class MetricHistoryTests: XCTestCase {
    private func snapshot(
        cpu: Double? = 0.5,
        gpu: Double? = 0.3,
        netDown: Double? = 100,
        netUp: Double? = 50
    ) -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.cpuUsage = cpu.map { CPUUsageReading(total: $0, user: $0 * 0.6, system: $0 * 0.4) }
        snap.gpuUsage = gpu
        snap.netDownBytesPerSec = netDown
        snap.netUpBytesPerSec = netUp
        return snap
    }

    func test_appendCollectsAllSeries() {
        var history = MetricHistory()
        history.append(snapshot())
        history.append(snapshot(cpu: 0.7, gpu: 0.4, netDown: 200, netUp: 90))

        XCTAssertEqual(history.cpu, [0.5, 0.7])
        XCTAssertEqual(history.gpu, [0.3, 0.4])
        XCTAssertEqual(history.netDown, [100, 200])
        XCTAssertEqual(history.netUp, [50, 90])
    }

    func test_appendSkipsNilValues() {
        var history = MetricHistory()
        history.append(snapshot(cpu: nil, netUp: nil))
        history.append(snapshot(cpu: 0.6))

        XCTAssertEqual(history.cpu, [0.6])
        XCTAssertEqual(history.gpu, [0.3, 0.3])
        XCTAssertEqual(history.netDown, [100, 100])
        XCTAssertEqual(history.netUp, [50])
    }

    func test_appendTruncatesBeyondCapacity() {
        var history = MetricHistory()
        for i in 0..<(MetricHistory.capacity + 10) {
            history.append(snapshot(cpu: Double(i)))
        }
        XCTAssertEqual(history.cpu.count, MetricHistory.capacity)
        // 最早的数据被丢弃，保留最近 capacity 个
        XCTAssertEqual(history.cpu.first, 10)
        XCTAssertEqual(history.cpu.last, Double(MetricHistory.capacity + 9))
    }

    func test_resetClearsAllSeries() {
        var history = MetricHistory()
        history.append(snapshot())
        history.reset()
        XCTAssertTrue(history.cpu.isEmpty)
        XCTAssertTrue(history.gpu.isEmpty)
        XCTAssertTrue(history.netDown.isEmpty)
        XCTAssertTrue(history.netUp.isEmpty)
    }

    func test_equality() {
        var a = MetricHistory()
        a.append(snapshot())
        var b = MetricHistory()
        b.append(snapshot())
        XCTAssertEqual(a, b)
        b.append(snapshot(cpu: 0.9))
        XCTAssertNotEqual(a, b)
    }
}
