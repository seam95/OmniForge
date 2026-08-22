import Foundation

/// Render unit for the overview grid — group 层已拍平为 `.metric` 直映射。
enum MonitorOverviewCardGroup: Equatable, Identifiable {
    case metric(MonitorCardModel)

    var id: String {
        switch self {
        case let .metric(model):
            return "metric.\(model.id.rawValue)"
        }
    }

    var metricModel: MonitorCardModel? {
        switch self {
        case let .metric(model):
            return model
        }
    }

    static func groups(from models: [MonitorCardModel]) -> [MonitorOverviewCardGroup] {
        models.map { .metric($0) }
    }

    /// 固定四行：CPU|内存 → 网络整宽 → 电池|GPU → 磁盘整宽（按可见性取行）。
    static func dashboardRows(from models: [MonitorCardModel]) -> [MonitorOverviewRow] {
        let groups = groups(from: models)
        let byCardID = Dictionary(
            uniqueKeysWithValues: groups.compactMap { group -> (MonitorCardID, MonitorOverviewCardGroup)? in
                guard let model = group.metricModel else { return nil }
                return (model.id, group)
            }
        )

        var rows: [MonitorOverviewRow] = []
        appendPairRow(id: "row.cpuMemory", first: byCardID[.cpu], second: byCardID[.memory], to: &rows)

        if let network = byCardID[.network] {
            rows.append(.single(network, id: "row.network"))
        }

        appendPairRow(id: "row.batteryGPU", first: byCardID[.battery], second: byCardID[.gpu], to: &rows)

        if let disk = byCardID[.disk] {
            rows.append(.single(disk, id: "row.disk"))
        }

        return rows
    }

    private static func appendPairRow(
        id: String,
        first: MonitorOverviewCardGroup?,
        second: MonitorOverviewCardGroup?,
        to rows: inout [MonitorOverviewRow]
    ) {
        switch (first, second) {
        case let (.some(first), .some(second)):
            rows.append(.pair(first, second, id: id))
        case let (.some(group), .none), let (.none, .some(group)):
            rows.append(.single(group, id: id))
        case (.none, .none):
            break
        }
    }
}

/// Fixed dashboard rows for the overview page. Explicit rows keep card heights aligned.
enum MonitorOverviewRow: Equatable, Identifiable {
    case single(MonitorOverviewCardGroup, id: String)
    case pair(MonitorOverviewCardGroup, MonitorOverviewCardGroup, id: String)

    var id: String {
        switch self {
        case let .single(_, id), let .pair(_, _, id):
            return id
        }
    }

    var height: CGFloat {
        switch id {
        case "row.cpuMemory":
            return 100
        case "row.network":
            return 96
        case "row.batteryGPU":
            return 100
        case "row.disk":
            return 82
        default:
            return 96
        }
    }

    var displayKinds: [MonitorOverviewDisplayKind] {
        switch self {
        case let .single(group, _):
            return [group.displayKind]
        case let .pair(left, right, _):
            return [left.displayKind, right.displayKind]
        }
    }
}

enum MonitorOverviewDisplayKind: Equatable {
    case cpuTrend
    case memoryGauge
    case networkDual
    case batteryBar
    case gpuTrend
    case diskChips
}

extension MonitorOverviewCardGroup {
    var displayKind: MonitorOverviewDisplayKind {
        switch self {
        case let .metric(model):
            switch model.id {
            case .cpu: return .cpuTrend
            case .memory: return .memoryGauge
            case .network: return .networkDual
            case .battery: return .batteryBar
            case .gpu: return .gpuTrend
            case .disk: return .diskChips
            case .energy: return .cpuTrend // overview 无入口，不可达
            }
        }
    }
}
