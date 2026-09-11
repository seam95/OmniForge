import XCTest
@testable import OmniForge

final class MetricHistoryTests: XCTestCase {
    /// 默认固定 sampledAt，保证涉及时间戳/相等性的断言确定性
    private func snapshot(
        cpu: Double? = 0.5,
        gpu: Double? = 0.3,
        memory: Double? = 0.6,
        netDown: Double? = 100,
        netUp: Double? = 50,
        sampledAt: Date = Date(timeIntervalSince1970: 0)
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
        snap.sampledAt = sampledAt
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
        XCTAssertTrue(history.cpuTimes.isEmpty)
        XCTAssertTrue(history.netDownTimes.isEmpty)
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

    // MARK: - 采样时刻

    /// 值与时刻逐点配对：append 后各序列时间戳等于 sampledAt
    func test_appendPairsTimestampsWithValues() {
        var history = MetricHistory()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_002)
        history.append(snapshot(sampledAt: t1))
        history.append(snapshot(cpu: 0.7, sampledAt: t2))

        XCTAssertEqual(history.cpuTimes, [t1, t2])
        XCTAssertEqual(history.gpuTimes, [t1, t2])
        XCTAssertEqual(history.netDownTimes, [t1, t2])
        XCTAssertEqual(history.netUpTimes, [t1, t2])
    }

    /// 缺读数跳过时该序列时间戳同步跳过，不同序列时刻集可不同
    func test_appendSkipsTimestampsWithMissingValues() {
        var history = MetricHistory()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_002)
        history.append(snapshot(cpu: nil, sampledAt: t1))
        history.append(snapshot(cpu: 0.6, sampledAt: t2))

        XCTAssertEqual(history.cpu, [0.6])
        XCTAssertEqual(history.cpuTimes, [t2])
        XCTAssertEqual(history.gpuTimes, [t1, t2])
    }

    /// sampledAt 缺失回退当前时刻，时间戳恒可用
    func test_appendFallsBackToNowWhenSampledAtMissing() {
        var history = MetricHistory()
        var snap = snapshot()
        snap.sampledAt = nil
        let before = Date()
        history.append(snap)
        let after = Date()

        XCTAssertEqual(history.cpuTimes.count, 1)
        if let time = history.cpuTimes.first {
            XCTAssertTrue(time >= before && time <= after)
        }
    }

    /// 超容量时值与时刻同步裁剪，最早的配对整点丢弃
    func test_appendTruncatesTimestampsBeyondCapacity() {
        var history = MetricHistory()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<(MetricHistory.capacity + 10) {
            history.append(snapshot(cpu: Double(i), sampledAt: base.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(history.cpuTimes.count, MetricHistory.capacity)
        XCTAssertEqual(history.cpuTimes.first, base.addingTimeInterval(10))
        XCTAssertEqual(history.cpuTimes.last, base.addingTimeInterval(Double(MetricHistory.capacity + 9)))
    }

    /// 时刻参与相等性判断：同值不同时刻的序列不相等
    func test_equalityIncludesTimestamps() {
        var a = MetricHistory()
        a.append(snapshot(sampledAt: Date(timeIntervalSince1970: 1)))
        var b = MetricHistory()
        b.append(snapshot(sampledAt: Date(timeIntervalSince1970: 2)))
        XCTAssertNotEqual(a, b)
    }
}
