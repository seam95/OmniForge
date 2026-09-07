import Foundation

/// 采样策略 — 根据面板/菜单栏/告警需求决定各指标的采样间隔
struct MonitorSamplingPolicy {
    let baseTick: Int  // 1, 2, 或 5 秒

    /// 前台采样间隔（面板展开）— 每个基础 tick 都采样
    func foregroundInterval(for metric: MonitorMetric) -> TimeInterval {
        TimeInterval(baseTick)
    }

    /// 后台采样间隔（仅菜单栏或告警活跃）
    func backgroundInterval(for metric: MonitorMetric) -> TimeInterval {
        switch metric {
        case .cpu, .memory, .network:
            return 1.0
        case .gpu:
            return 10.0
        case .disk:
            return 10.0
        case .power, .cpuTemperature, .gpuTemperature, .batteryTemperature:
            return 15.0
        case .peripheralBattery:
            return 60.0
        case .fan:
            return 15.0
        case .fanSensor:
            return 15.0
        }
    }

    /// 后台模式下每 N 个 tick 采样一次该指标
    func backgroundTickStride(for metric: MonitorMetric) -> Int {
        let interval = backgroundInterval(for: metric)
        return max(1, Int((interval / Double(baseTick)).rounded()))
    }

    /// 根据需求判定是否应在每个 tick 采样（保留兼容性）
    func shouldSample(_ metric: MonitorMetric, demand: MonitorDemand, isForeground: Bool) -> Bool {
        let interval = isForeground ? foregroundInterval(for: metric) : backgroundInterval(for: metric)
        return interval <= TimeInterval(baseTick)
    }
}
