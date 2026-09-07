import Foundation

/// 风扇页传感器分组摘要 — 纯函数计算每个热区的聚合展示形态。
/// 组内明细按温度降序（热点在前），摘要行主指标为组内最高温 + 热点传感器名。
struct FanSensorGroupSummary: Equatable {
    let zone: ThermalZone
    /// 组内明细，按温度降序；Swift sort 稳定，并列温度保持发现序
    let sensors: [FanSensorReading]

    /// 组内最高温读数；summaries 只产出非空组，防御式可空
    var hottest: FanSensorReading? { sensors.first }

    /// 全量读数 → 热区摘要列表。分组顺序沿用 ThermalZone.allCases（与采样发现序一致）；
    /// unknown 组默认过滤（未分类 SMC key 对用户价值低，参照 Stats 默认隐藏配方）。
    static func summaries(
        from readings: [FanSensorReading],
        hidingUnknown: Bool = true
    ) -> [FanSensorGroupSummary] {
        let grouped = Dictionary(grouping: readings, by: \.zone)
        return ThermalZone.allCases.compactMap { zone in
            guard var items = grouped[zone], !items.isEmpty else { return nil }
            if zone == .unknown, hidingUnknown { return nil }
            items.sort { $0.temperatureCelsius > $1.temperatureCelsius }
            return FanSensorGroupSummary(zone: zone, sensors: items)
        }
    }

    /// 被隐藏的未分类传感器数量 — 供区底透明说明（非 0 时展示）
    static func hiddenUnknownCount(from readings: [FanSensorReading]) -> Int {
        readings.filter { $0.zone == .unknown }.count
    }
}
