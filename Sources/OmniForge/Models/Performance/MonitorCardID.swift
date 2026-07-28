import Foundation

/// Overview panel card identifiers mapped from `MonitorConfiguration`.
enum MonitorCardID: String, CaseIterable, Hashable {
    case cpu
    case memory
    case battery
    case disk
    case network
    case gpu
    case energy

    /// Rankable process metric for cards that support process breakdown.
    var processMetricKind: ProcessMetricKind? {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .network: return .network
        case .energy: return .energy
        case .battery, .disk: return nil
        }
    }

    /// Network occupies a full-width row in the overview grid.
    var isFullWidth: Bool {
        self == .network
    }

    /// Core cards always attempted first, in fixed order.
    private static let coreOrder: [MonitorCardID] = [
        .cpu, .memory, .battery, .disk, .network
    ]

    /// Extension cards (diskIO 已合并入 disk 卡，不再出现在扩展卡列表中)
    private static let extensionCards: [MonitorCardID] = [
        .gpu, .energy
    ]

    /// Returns visible overview cards for the given configuration.
    ///
    /// Core five cards are inserted first (fixed order among those visible),
    /// then extension cards ordered by `configuration.panelSectionOrder`
    /// (system → gpu, disk → diskIO, power → energy), each only if still visible
    /// under section ∩ metric rules.
    static func visibleCards(configuration: MonitorConfiguration) -> [MonitorCardID] {
        var result: [MonitorCardID] = []
        for card in coreOrder where card.isVisible(in: configuration) {
            result.append(card)
        }

        let sectionRank: [MonitorSection: Int] = Dictionary(
            uniqueKeysWithValues: configuration.panelSectionOrder.enumerated().map { ($0.element, $0.offset) }
        )
        let extensions = extensionCards
            .filter { $0.isVisible(in: configuration) }
            .sorted { lhs, rhs in
                let l = sectionRank[lhs.section] ?? Int.max
                let r = sectionRank[rhs.section] ?? Int.max
                if l != r { return l < r }
                // Stable fallback if ranks equal/missing.
                return (extensionCards.firstIndex(of: lhs) ?? 0) < (extensionCards.firstIndex(of: rhs) ?? 0)
            }
        result.append(contentsOf: extensions)
        return result
    }

    private func isVisible(in configuration: MonitorConfiguration) -> Bool {
        configuration.visibleSections.contains(section)
            && configuration.visiblePanelMetrics.contains(metric)
    }

    private var section: MonitorSection {
        switch self {
        case .cpu, .memory, .gpu: return .system
        case .battery, .energy: return .power
        case .disk: return .disk
        case .network: return .network
        }
    }

    private var metric: MonitorMetric {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .gpu: return .gpu
        case .battery, .energy: return .power
        case .disk: return .disk
        case .network: return .network
        }
    }
}
