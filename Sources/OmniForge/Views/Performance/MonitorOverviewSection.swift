import Foundation

/// Overview 平面分区：CPU/GPU/内存三列指标区 → 网络 → 磁盘 → 电池（各自全宽）。
/// 显隐由可见卡列表驱动；分隔线由渲染层按相邻分区插入。
enum MonitorOverviewSection: Equatable, Identifiable {
    /// 三列指标区（CPU/GPU/内存共用列结构：标签+当前值 → 大数字 → 迷你折线）
    case metrics([MonitorCardModel])
    case network(MonitorCardModel)
    case disk(MonitorCardModel)
    case battery(MonitorCardModel)

    var id: String {
        switch self {
        case .metrics: return "section.metrics"
        case .network: return "section.network"
        case .disk: return "section.disk"
        case .battery: return "section.battery"
        }
    }

    /// 单模型分区的模型；三列分区无单一模型返回 nil。
    var model: MonitorCardModel? {
        switch self {
        case let .network(model), let .disk(model), let .battery(model):
            return model
        case .metrics:
            return nil
        }
    }

    /// 渲染层取标签色块用的分区主色卡 ID；三列分区取首列（CPU）。
    var accentCardID: MonitorCardID? {
        switch self {
        case let .metrics(models):
            return models.first?.id
        case let .network(model), let .disk(model), let .battery(model):
            return model.id
        }
    }
}

/// 从可见卡模型规划 overview 分区 — 纯函数，独立可测。
enum MonitorOverviewSectionPlanner {
    /// 三列指标区固定顺序。
    private static let metricOrder: [MonitorCardID] = [.cpu, .gpu, .memory]

    static func sections(from models: [MonitorCardModel]) -> [MonitorOverviewSection] {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        var result: [MonitorOverviewSection] = []

        let metrics = metricOrder.compactMap { byID[$0] }
        if !metrics.isEmpty {
            result.append(.metrics(metrics))
        }
        if let network = byID[.network] {
            result.append(.network(network))
        }
        if let disk = byID[.disk] {
            result.append(.disk(disk))
        }
        if let battery = byID[.battery] {
            result.append(.battery(battery))
        }
        return result
    }
}
