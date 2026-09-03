import Foundation

/// Overview 平面分区：三栏（CPU/GPU/内存）→ 网络 → 磁盘 → 电池。
/// 显隐由可见卡列表驱动；分隔线由渲染层按相邻分区插入。
enum MonitorOverviewSection: Equatable, Identifiable {
    /// 三栏指标区（1~3 栏，等宽排列）
    case triple([MonitorCardModel])
    case network(MonitorCardModel)
    case disk(MonitorCardModel)
    case battery(MonitorCardModel)

    var id: String {
        switch self {
        case .triple: return "section.triple"
        case .network: return "section.network"
        case .disk: return "section.disk"
        case .battery: return "section.battery"
        }
    }

    var model: MonitorCardModel? {
        switch self {
        case let .triple(models): return models.first
        case let .network(model), let .disk(model), let .battery(model): return model
        }
    }
}

/// 从可见卡模型规划 overview 分区 — 纯函数，独立可测。
enum MonitorOverviewSectionPlanner {
    /// 三栏栏位固定顺序。
    private static let tripleOrder: [MonitorCardID] = [.cpu, .gpu, .memory]

    static func sections(from models: [MonitorCardModel]) -> [MonitorOverviewSection] {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        var result: [MonitorOverviewSection] = []

        let tripleModels = tripleOrder.compactMap { byID[$0] }
        if !tripleModels.isEmpty {
            result.append(.triple(tripleModels))
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
