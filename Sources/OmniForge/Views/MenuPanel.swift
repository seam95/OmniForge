import Foundation

enum MenuPanel: String, CaseIterable, Identifiable {
    case systemMonitor
    case tokenUsage
    case keepAwake
    case providerSwitch
    case clipboard = "utilities"

    /// 兼容历史命名；控制中心实用工具页。
    static let utilities: MenuPanel = .clipboard

    /// 系统监控 → Token 用量 → 保持唤醒 → 供应商切换 → 实用工具
    static let primaryCases: [MenuPanel] = [
        .systemMonitor, .tokenUsage, .keepAwake, .providerSwitch, .utilities,
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
        if isAvailable(.providerSwitch) {
            result.append(.providerSwitch)
        }
        if isAvailable(.cleaner)
            || isAvailable(.uninstaller)
            || isAvailable(.colorPicker)
            || isAvailable(.networkDiagnostics)
            || isAvailable(.dshWeb)
            || isAvailable(.cleaningMode) {
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
        case .providerSwitch: return "arrow.triangle.swap"
        case .clipboard: return "wrench.fill"
        }
    }

    func title(in strings: Strings) -> String {
        switch self {
        case .systemMonitor: return strings.controlcenterTabSystemMonitor
        case .tokenUsage: return strings.controlcenterTabTokenUsage
        case .keepAwake: return strings.featureHubNameKeepAwake
        case .providerSwitch: return strings.controlcenterTabProviderSwitch
        case .clipboard: return strings.controlcenterTabUtilities
        }
    }

    func navTitle(in strings: Strings) -> String {
        switch self {
        case .systemMonitor: return strings.controlcenterNavMonitor
        case .tokenUsage: return strings.controlcenterNavTokenUsage
        case .keepAwake: return strings.controlcenterNavKeepAwake
        case .providerSwitch: return strings.controlcenterNavProviderSwitch
        case .clipboard: return strings.controlcenterNavUtilities
        }
    }

    /// 控制中心平面白底风格面板（footer flat、按钮主色等统一样式判定）。
    /// 全部主 tab 均为平面风格；监控 overview 的浅色白底由其内层 route 持有，
    /// 宿主转场层 surface 不重复给白底（见 ControlCenterContainerView.panelSurface）。
    var usesFlatChrome: Bool {
        switch self {
        case .systemMonitor, .tokenUsage, .keepAwake, .providerSwitch, .clipboard:
            return true
        }
    }
}
