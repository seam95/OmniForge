import Foundation

/// Render unit for the overview grid. Power data is grouped visually while preserving existing card models.
enum MonitorOverviewCardGroup: Equatable, Identifiable {
    case metric(MonitorCardModel)
    case power(battery: MonitorCardModel, energy: MonitorCardModel)

    var id: String {
        switch self {
        case let .metric(model):
            return "metric.\(model.id.rawValue)"
        case .power:
            return "power.battery-energy"
        }
    }

    var isFullWidth: Bool {
        switch self {
        case let .metric(model):
            return model.id.isFullWidth
        case .power:
            return false
        }
    }

    var energyModel: MonitorCardModel? {
        switch self {
        case let .metric(model) where model.id == .energy:
            return model
        case let .power(_, energy):
            return energy
        case .metric:
            return nil
        }
    }

    static func groups(from models: [MonitorCardModel]) -> [MonitorOverviewCardGroup] {
        let energy = models.first { $0.id == .energy }
        var groups: [MonitorOverviewCardGroup] = []

        for model in models {
            switch model.id {
            case .battery:
                if let energy {
                    groups.append(.power(battery: model, energy: energy))
                } else {
                    groups.append(.metric(model))
                }
            case .energy:
                if models.contains(where: { $0.id == .battery }) {
                    continue
                }
                groups.append(.metric(model))
            default:
                groups.append(.metric(model))
            }
        }

        return groups
    }

    static func dashboardRows(from models: [MonitorCardModel]) -> [MonitorOverviewRow] {
        let groups = groups(from: models)
        let byCardID = Dictionary(
            uniqueKeysWithValues: groups.compactMap { group -> (MonitorCardID, MonitorOverviewCardGroup)? in
                switch group {
                case let .metric(model):
                    return (model.id, group)
                case .power:
                    return (.battery, group)
                }
            }
        )

        var rows: [MonitorOverviewRow] = []
        appendPairRow(id: "row.top", first: byCardID[.cpu], second: byCardID[.memory], to: &rows)

        if let power = byCardID[.battery] {
            rows.append(.single(power, id: "row.power"))
        }

        if let disk = byCardID[.disk] {
            rows.append(.single(disk, id: "row.disk"))
        }

        appendPairRow(id: "row.bottom", first: byCardID[.network], second: byCardID[.gpu], to: &rows)

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
        case "row.top":
            return 122
        case "row.power":
            return 78
        case "row.disk":
            return 88
        case "row.bottom":
            return 104
        default:
            return 104
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
    case cpuGauge
    case memoryDashboard
    case powerStrip
    case diskThroughput
    case metric
}

extension MonitorOverviewCardGroup {
    var displayKind: MonitorOverviewDisplayKind {
        switch self {
        case let .metric(model):
            switch model.id {
            case .cpu:
                return .cpuGauge
            case .memory:
                return .memoryDashboard
            case .disk:
                return .diskThroughput
            default:
                return .metric
            }
        case .power:
            return .powerStrip
        }
    }
}
