import Foundation

/// 系统全部实时指标的单一快照 — 不包含任何历史数组
struct SystemSnapshot {
    // 温度
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var batteryTemperature: Double?

    // CPU / GPU / 内存
    var cpuUsage: CPUUsageReading?
    var gpuUsage: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var memoryPressure = MemoryPressure.unknown

    // 网络
    var netDownBytesPerSec: Double?
    var netUpBytesPerSec: Double?
    var netTotalDown: UInt64?
    var netTotalUp: UInt64?

    // 电源
    var power: PowerReading?

    // 外设电量
    var peripheralBatteries: [PeripheralBatteryDevice] = []

    // 磁盘
    var disk: DiskReading?

    // 问题记录 — 失败即记录，不清零
    var issues: [MonitorMetric: MetricIssue] = [:]

    // 采样时间
    var sampledAt: Date?
}
