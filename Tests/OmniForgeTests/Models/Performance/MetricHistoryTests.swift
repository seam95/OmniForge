import XCTest
@testable import OmniForge

final class MetricHistoryTests: XCTestCase {
    private func snapshot(
        cpu: Double? = 0.5,
        gpu: Double? = 0.3,
        memory: Double? = 0.6,
        netDown: Double? = 100,
        netUp: Double? = 50
    ) -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.cpuUsage = cpu.map { CPUUsageReading(total: $0, user: $0 * 0.6, system: $0 * 0.4) }
        snap.gpuUsage = gpu
        if let memory {
            snap.memoryTotal = 16_000_000_000
            snap.memoryUsed = UInt64(memory * 16_000_000_000)
        }
        snap.netDownBytesPerSec = netDown
        snap.netUpBytesPerSec = netUp
        return snap
    }

    func test_appendCollectsAllSeries() {
        var history = MetricHistory()
        history.append(snapshot())
        history.append(snapshot(cpu: 0.7, gpu: 0.4, memory: 0.7, netDown: 200, netUp: 90))

        XCTAssertEqual(history.cpu, [0.5, 0.7])
        XCTAssertEqual(history.gpu, [0.3, 0.4])
        // 占用比经 UInt64 字节数截断，断言用误差容忍
        XCTAssertEqual(history.memory.count, 2)
        XCTAssertEqual(history.memory[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(history.memory[1], 0.7, accuracy: 0.0001)
        XCTAssertEqual(history.netDown, [100, 200])
        XCTAssertEqual(history.netUp, [50, 90])
    }

    func test_appendSkipsNilValues() {
        var history = MetricHistory()
        history.append(snapshot(cpu: nil, memory: nil, netUp: nil))
        history.append(snapshot(cpu: 0.6))

        XCTAssertEqual(history.cpu, [0.6])
        XCTAssertEqual(history.gpu, [0.3, 0.3])
        XCTAssertEqual(history.memory.count, 1)
        XCTAssertEqual(history.memory[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(history.netDown, [100, 100])
        XCTAssertEqual(history.netUp, [50])
    }

    /// total 缺失/为 0 时内存序列不追加，保持与快照频率对齐
    func test_appendSkipsMemoryWhenTotalMissing() {
        var history = MetricHistory()
        var snap = snapshot()
        snap.memoryUsed = 8_000_000_000
        snap.memoryTotal = nil
        history.append(snap)
        snap.memoryTotal = 0
        history.append(snap)

        XCTAssertTrue(history.memory.isEmpty)
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
        XCTAssertTrue(history.memory.isEmpty)
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
