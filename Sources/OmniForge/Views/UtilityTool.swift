import Foundation

enum UtilityTool: String, CaseIterable, Identifiable {
    case cleaner
    case uninstaller
    case colorPicker
    case networkDiagnostics

    var id: String { rawValue }

    static func visibleCases(isAvailable: (AppFeature) -> Bool) -> [UtilityTool] {
        allCases.filter { tool in
            switch tool {
            case .cleaner:
                return isAvailable(.cleaner)
            case .uninstaller:
                return isAvailable(.uninstaller)
            case .colorPicker:
                return isAvailable(.colorPicker)
            case .networkDiagnostics:
                return isAvailable(.networkDiagnostics)
            }
        }
    }

    static func resolvedSelection(
        _ selection: UtilityTool?,
        in visibleCases: [UtilityTool]
    ) -> UtilityTool? {
        guard let first = visibleCases.first else { return nil }
        guard let selection, visibleCases.contains(selection) else { return first }
        return selection
    }

    func title(in strings: Strings) -> String {
        switch self {
        case .cleaner:
            return strings.utilityCleaner
        case .uninstaller:
            return strings.utilityUninstaller
        case .colorPicker:
            return strings.colorPickerName
        case .networkDiagnostics:
            return strings.featureHubNameNetworkDiagnostics
        }
    }

    /// 对应的功能目录项，用于复用图标 / 名称 / 描述，避免重复定义展示元数据。
    var feature: AppFeature {
        switch self {
        case .cleaner:
            return .cleaner
        case .uninstaller:
            return .uninstaller
        case .colorPicker:
            return .colorPicker
        case .networkDiagnostics:
            return .networkDiagnostics
        }
    }

    /// 列表行展示的 SF Symbol。
    func symbolName() -> String { feature.symbolName }

    /// 列表行展示的本地化名称（与 FeatureHub 统一）。
    func hubName(in strings: Strings) -> String { feature.hubName(in: strings) }

    /// 列表行展示的本地化描述。
    func hubDescription(in strings: Strings) -> String { feature.hubDescription(in: strings) }
}
