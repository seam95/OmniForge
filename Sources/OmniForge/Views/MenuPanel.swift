import Foundation

enum MenuPanel: String, CaseIterable, Identifiable {
    case systemMonitor
    case tokenUsage
    case keepAwake
    case clipboard = "utilities"

    /// 兼容历史命名；控制中心实用工具页。
    static let utilities: MenuPanel = .clipboard

    /// 系统监控 → Token 用量 → 保持唤醒 → 实用工具
    static let primaryCases: [MenuPanel] = [
        .systemMonitor, .tokenUsage, .keepAwake, .utilities,
    ]

    static func visibleCases(isAvailable: (AppFeature) -> Bool) -> [MenuPanel] {
        var result: [MenuPanel] = []

        if isAvailable(.systemMonitor) {
            result.append(.systemMonitor)
        }
        if isAvailable(.tokenUsage) {
            result.append(.tokenUsage)
        }
        if isAvailable(.keepAwake) {
            result.append(.keepAwake)
        }
        if isAvailable(.cleaner)
            || isAvailable(.uninstaller)
            || isAvailable(.colorPicker)
            || isAvailable(.networkDiagnostics)
            || isAvailable(.dshWeb) {
            result.append(.utilities)
        }

        return result
    }

    static func resolvedSelection(
        _ selection: MenuPanel?,
        in visibleCases: [MenuPanel]
    ) -> MenuPanel? {
        guard let first = visibleCases.first else { return nil }
        guard let selection, visibleCases.contains(selection) else { return first }
        return selection
    }

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .systemMonitor: return "waveform.path.ecg"
        case .tokenUsage: return "chart.line.uptrend.xyaxis"
        case .keepAwake: return "moon.fill"
        case .clipboard: return "wrench.fill"
        }
    }

    func title(in strings: Strings) -> String {
        switch self {
        case .systemMonitor: return strings.controlcenterTabSystemMonitor
        case .tokenUsage: return strings.controlcenterTabTokenUsage
        case .keepAwake: return strings.featureHubNameKeepAwake
        case .clipboard: return strings.controlcenterTabUtilities
        }
    }

    func navTitle(in strings: Strings) -> String {
        switch self {
        case .systemMonitor: return strings.controlcenterNavMonitor
        case .tokenUsage: return strings.controlcenterNavTokenUsage
        case .keepAwake: return strings.controlcenterNavKeepAwake
        case .clipboard: return strings.controlcenterNavUtilities
        }
    }
}
