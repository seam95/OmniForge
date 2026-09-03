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

    /// Overview 固定卡片顺序：CPU|GPU|内存 三栏 → 网络整宽 → 磁盘 → 电池。
    private static let fixedOrder: [MonitorCardID] = [
        .cpu, .gpu, .memory, .network, .disk, .battery
    ]

    /// Returns visible overview cards for the given configuration.
    ///
    /// 固定顺序 + 按「隐藏分区」开关过滤；隐藏即不显示（且上层停止采样）。
    /// `.energy` 不再出现在 overview。
    static func visibleCards(configuration: MonitorConfiguration) -> [MonitorCardID] {
        fixedOrder.filter { $0.isVisible(in: configuration) }
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
