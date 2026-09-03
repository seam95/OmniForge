import Foundation

/// Overview 平面分区：CPU/GPU/内存全宽指标区 → 网络 → 磁盘+电池两栏。
/// 显隐由可见卡列表驱动；分隔线由渲染层按相邻分区插入。
enum MonitorOverviewSection: Equatable, Identifiable {
    /// 全宽指标区（CPU/GPU/内存共用结构：标签行 + 大数字 + 折线）
    case metric(MonitorCardModel)
    case network(MonitorCardModel)
    /// 磁盘+电池左右两栏（两者都可见时）
    case diskBattery(disk: MonitorCardModel, battery: MonitorCardModel)
    /// 磁盘独占全宽（电池被隐藏时）
    case disk(MonitorCardModel)
    /// 电池独占全宽（磁盘被隐藏时）
    case battery(MonitorCardModel)

    var id: String {
        switch self {
        case let .metric(model): return "section.metric.\(model.id)"
        case .network: return "section.network"
        case .diskBattery: return "section.diskBattery"
        case .disk: return "section.disk"
        case .battery: return "section.battery"
        }
    }

    /// 单模型分区的模型；两栏分区无单一模型返回 nil。
    var model: MonitorCardModel? {
        switch self {
        case let .metric(model), let .network(model), let .disk(model), let .battery(model):
            return model
        case .diskBattery:
            return nil
        }
    }

    /// 渲染层取标签色块用的分区主色卡 ID；两栏分区返回磁盘（首栏）。
    var accentCardID: MonitorCardID? {
        switch self {
        case let .metric(model), let .network(model), let .disk(model), let .battery(model):
            return model.id
        case let .diskBattery(disk, _):
            return disk.id
        }
    }
}

/// 从可见卡模型规划 overview 分区 — 纯函数，独立可测。
enum MonitorOverviewSectionPlanner {
    /// 全宽指标区固定顺序。
    private static let metricOrder: [MonitorCardID] = [.cpu, .gpu, .memory]

    static func sections(from models: [MonitorCardModel]) -> [MonitorOverviewSection] {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        var result: [MonitorOverviewSection] = []

        for id in metricOrder {
            if let model = byID[id] {
                result.append(.metric(model))
            }
        }
        if let network = byID[.network] {
            result.append(.network(network))
        }
        switch (byID[.disk], byID[.battery]) {
        case let (disk?, battery?):
            result.append(.diskBattery(disk: disk, battery: battery))
        case let (disk?, nil):
            result.append(.disk(disk))
        case let (nil, battery?):
            result.append(.battery(battery))
        case (nil, nil):
            break
        }
        return result
    }
}
