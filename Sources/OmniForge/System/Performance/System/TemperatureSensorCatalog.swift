import Foundation
import OmniForgeSMC

/// 温度传感器目录 — 首轮枚举 SMC key（T 前缀 + 值域过滤）锁定活跃集，
/// 其后每轮仅轮询活跃集，避免对不存在的 key 反复发起 IOKit 调用。
final class TemperatureSensorCatalog: TemperatureSensorScanning {
    private let smc: FanSMCCommanding & SMCKeyEnumerating
    /// 已锁定的活跃传感器（key/label/zone），nil = 尚未完成首轮发现
    private var activeSensors: [(key: String, label: String, zone: ThermalZone)]?

    init(smc: FanSMCCommanding & SMCKeyEnumerating) {
        self.smc = smc
    }

    func sampleSensors() throws -> [FanSensorReading] {
        if activeSensors == nil {
            activeSensors = discoverSensors()
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

    /// 枚举全部 SMC key，T 前缀且可读、值域合理者收编；按热区序 + key 字典序稳定排序
    private func discoverSensors() -> [(key: String, label: String, zone: ThermalZone)] {
        guard let total = smc.totalKeyCount() else { return [] }
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
