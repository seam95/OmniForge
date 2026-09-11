import Foundation

/// 单序列趋势读数 — 值与采样时刻逐点配对，支撑悬浮气泡回显时间。
/// 值与时刻同进同出（跳过/裁剪同步），保证 `timestamps[index]` 恒为 `values[index]` 的采样时间。
struct TimedSeries: Equatable {
    private(set) var values: [Double] = []
    private(set) var timestamps: [Date] = []

    var isEmpty: Bool { values.isEmpty }

    mutating func append(_ value: Double, at time: Date) {
        values.append(value)
        timestamps.append(time)
        if values.count > MetricHistory.capacity {
            values.removeFirst(values.count - MetricHistory.capacity)
            timestamps.removeFirst(timestamps.count - MetricHistory.capacity)
        }
    }

    mutating func removeAll() {
        values.removeAll()
        timestamps.removeAll()
    }
}

/// 监控指标环形缓冲 — 支撑面板卡片的趋势折线。
///
/// 简单数组 `append` + 超容量 `removeFirst`（容量 120，开销可忽略），
/// 不用真环形索引：易测、Equatable 现成。仅前台采样时追加。
/// 各序列内部存值+时刻配对（`TimedSeries`），对外暴露只读数组保持既有消费方兼容；
/// 注意序列间不保证等长（缺读数的轮次仅跳过对应序列）。
struct MetricHistory: Equatable {
    /// 1s→2min / 2s→4min / 5s→10min
    static let capacity = 120

    private var cpuSeries = TimedSeries()      // 0...1
    private var gpuSeries = TimedSeries()      // 0...1
    private var memorySeries = TimedSeries()   // 占用比 0...1
    private var netDownSeries = TimedSeries()  // bytes/s
    private var netUpSeries = TimedSeries()    // bytes/s

    /// 只读值数组（既有消费方与测试沿用）
    var cpu: [Double] { cpuSeries.values }
    var gpu: [Double] { gpuSeries.values }
    var memory: [Double] { memorySeries.values }
    var netDown: [Double] { netDownSeries.values }
    var netUp: [Double] { netUpSeries.values }

    /// 各采样点的时刻，与值数组逐点配对（悬浮取值显示时间用）
    var cpuTimes: [Date] { cpuSeries.timestamps }
    var gpuTimes: [Date] { gpuSeries.timestamps }
    var memoryTimes: [Date] { memorySeries.timestamps }
    var netDownTimes: [Date] { netDownSeries.timestamps }
    var netUpTimes: [Date] { netUpSeries.timestamps }

    /// 从快照追加一轮读数；缺读数（nil）跳过不追加，保持历史对齐快照频率。
    /// 时刻取 `sampledAt`，缺失时回退当前时刻，保证时间戳恒可用。
    mutating func append(_ snapshot: SystemSnapshot) {
        let time = snapshot.sampledAt ?? Date()
        cpuSeries = Self.appended(snapshot.cpuUsage?.total, at: time, to: cpuSeries)
        gpuSeries = Self.appended(snapshot.gpuUsage, at: time, to: gpuSeries)
        memorySeries = Self.appended(Self.memoryFraction(snapshot), at: time, to: memorySeries)
        netDownSeries = Self.appended(snapshot.netDownBytesPerSec, at: time, to: netDownSeries)
        netUpSeries = Self.appended(snapshot.netUpBytesPerSec, at: time, to: netUpSeries)
    }

    mutating func reset() {
        cpuSeries.removeAll()
        gpuSeries.removeAll()
        memorySeries.removeAll()
        netDownSeries.removeAll()
        netUpSeries.removeAll()
    }

    /// 内存占用比；total 为 0 或缺失时返回 nil（本轮不追加）。
    private static func memoryFraction(_ snapshot: SystemSnapshot) -> Double? {
        guard let used = snapshot.memoryUsed, let total = snapshot.memoryTotal, total > 0 else {
            return nil
        }
        return Double(used) / Double(total)
    }

    private static func appended(_ value: Double?, at time: Date, to buffer: TimedSeries) -> TimedSeries {
        guard let value else { return buffer }
        var copy = buffer
        copy.append(value, at: time)
        return copy
    }
}
