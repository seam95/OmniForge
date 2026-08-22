import Foundation

/// 监控指标环形缓冲 — 支撑面板卡片的趋势折线。
///
/// 简单数组 `append` + 超容量 `removeFirst`（容量 120，开销可忽略），
/// 不用真环形索引：易测、Equatable 现成。仅前台采样时追加，保证等距 x 轴。
struct MetricHistory: Equatable {
    /// 1s→2min / 2s→4min / 5s→10min
    static let capacity = 120

    private(set) var cpu: [Double] = []     // 0...1
    private(set) var gpu: [Double] = []     // 0...1
    private(set) var netDown: [Double] = [] // bytes/s
    private(set) var netUp: [Double] = []   // bytes/s

    /// 从快照追加一轮读数；缺读数（nil）跳过不追加，保持历史对齐快照频率。
    mutating func append(_ snapshot: SystemSnapshot) {
        cpu = Self.appended(snapshot.cpuUsage?.total, to: cpu)
        gpu = Self.appended(snapshot.gpuUsage, to: gpu)
        netDown = Self.appended(snapshot.netDownBytesPerSec, to: netDown)
        netUp = Self.appended(snapshot.netUpBytesPerSec, to: netUp)
    }

    mutating func reset() {
        cpu = []
        gpu = []
        netDown = []
        netUp = []
    }

    private static func appended(_ value: Double?, to buffer: [Double]) -> [Double] {
        guard let value else { return buffer }
        var copy = buffer
        copy.append(value)
        if copy.count > capacity {
            copy.removeFirst(copy.count - capacity)
        }
        return copy
    }
}
