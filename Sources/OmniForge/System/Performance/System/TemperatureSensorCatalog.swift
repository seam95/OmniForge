import Foundation
import OmniForgeSMC

/// 温度传感器目录 — 首轮枚举 SMC key（T 前缀 + 值域过滤）锁定活跃集，
/// 其后每轮仅轮询活跃集，避免对不存在的 key 反复发起 IOKit 调用。
///
/// 发现失败不锁定空缓存（审查 R07）：totalKeyCount 读取失败（SMC 暂时
/// 不可达等）保留未发现状态，按指数退避重试，避免临时故障被缓存为
/// 永久「无传感器」。
final class TemperatureSensorCatalog: TemperatureSensorScanning {
    private let smc: FanSMCCommanding & SMCKeyEnumerating
    /// 已锁定的活跃传感器（key/label/zone）；nil = 尚未完成首轮发现（含重试退避中）
    private var activeSensors: [(key: String, label: String, zone: ThermalZone)]?
    /// 连续发现失败深度（指数翻倍）
    private var failureDepth = 0
    /// 剩余跳过轮数（退避窗口 1、2、4…，上限 32 轮 ≈ 1 分钟 @2s 周期）
    private var backoffRemaining = 0

    init(smc: FanSMCCommanding & SMCKeyEnumerating) {
        self.smc = smc
    }

    func sampleSensors() throws -> [FanSensorReading] {
        if activeSensors == nil {
            try discoverSensorsIfNeeded()
        }
        guard let active = activeSensors else { return [] }
        return active.compactMap { sensor in
            guard let value = smc.readDouble(forKey: sensor.key),
                  Self.isPlausible(value) else { return nil }
            return FanSensorReading(id: sensor.key, label: sensor.label,
                                    zone: sensor.zone, temperatureCelsius: value)
        }
    }

    // MARK: - 发现

    /// 退避窗口内的调用直接跳过发现（本轮返回空，等下一窗口再试）；
    /// 连续失败时窗口指数翻倍，恢复成功即清零。
    private func discoverSensorsIfNeeded() {
        if backoffRemaining > 0 {
            backoffRemaining -= 1
            return
        }
        // 发现成功无传感器 = 合法终态（空机型），锁定空集合；
        // 发现失败（totalKeyCount 读不到）= 保留未发现状态并退避。
        if let found = discoverSensors() {
            activeSensors = found
            failureDepth = 0
        } else {
            failureDepth = failureDepth == 0 ? 1 : min(failureDepth * 2, 32)
            backoffRemaining = failureDepth
        }
    }

    /// 枚举全部 SMC key，T 前缀且可读、值域合理者收编；按热区序 + key 字典序稳定排序。
    /// 返回 nil 表示发现失败（与「发现成功但无传感器」的空数组区分）。
    private func discoverSensors() -> [(key: String, label: String, zone: ThermalZone)]? {
        guard let total = smc.totalKeyCount() else { return nil }
        var found: [String] = []
        for index in 0..<total {
            guard let name = smc.keyName(at: index), name.hasPrefix("T") else { continue }
            guard let value = smc.readDouble(forKey: name), Self.isPlausible(value) else { continue }
            found.append(name)
        }
        return found
            .map { key in
                (key: key, label: Self.label(for: key),
                 zone: ThermalZone.zone(forSensorKey: key))
            }
            .sorted {
                let l = Self.zoneOrder($0.zone), r = Self.zoneOrder($1.zone)
                return l != r ? l < r : $0.key < $1.key
            }
    }

    /// 值域合理性 — 与既有温度采样口径一致
    static func isPlausible(_ value: Double) -> Bool {
        value > 1 && value < 125
    }

    /// 常见 key 的友好名；未映射时保留原码（对定位问题更有用）
    static func label(for key: String) -> String {
        knownLabels[key] ?? key
    }

    private static func zoneOrder(_ zone: ThermalZone) -> Int {
        ThermalZone.allCases.firstIndex(of: zone) ?? ThermalZone.allCases.count
    }

    private static let knownLabels: [String: String] = [
        "TB0T": "Battery Zone 1",
        "TB1T": "Battery Zone 2",
        "TB2T": "Battery Zone 3",
        "Ts0P": "Airflow",
        "TA0P": "Airflow",
        "TAOL": "Airflow (Left)",
        "TAOR": "Airflow (Right)",
        "Tm0P": "Memory Proximity",
        "TMVR": "Memory VRM",
        "TH0a": "SSD Controller",
        "TH0b": "SSD NAND",
        "TC0P": "CPU Package",
        "Tp09": "CPU P-core Cluster",
        "Tp01": "CPU P-core Cluster",
        "Tp05": "CPU P-core Cluster",
        "TG0P": "GPU",
        "TG0D": "GPU Die",
        "TM0P": "Mainboard",
    ]
}
