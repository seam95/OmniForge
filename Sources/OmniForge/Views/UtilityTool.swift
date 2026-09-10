import SwiftUI

enum UtilityTool: String, CaseIterable, Identifiable {
    // case 声明顺序即实用工具列表的展示顺序。
    case stickyNotes
    case dshWeb
    case networkDiagnostics
    case colorPicker
    case uninstaller
    case cleaner
    case cleaningMode
    case desktopPet
    case keepAwake

    var id: String { rawValue }

    static func visibleCases(isAvailable: (AppFeature) -> Bool) -> [UtilityTool] {
        allCases.filter { tool in
            switch tool {
            case .stickyNotes:
                return isAvailable(.stickyNotes)
            case .dshWeb:
                return isAvailable(.dshWeb)
            case .networkDiagnostics:
                return isAvailable(.networkDiagnostics)
            case .colorPicker:
                return isAvailable(.colorPicker)
            case .uninstaller:
                return isAvailable(.uninstaller)
            case .cleaner:
                return isAvailable(.cleaner)
            case .cleaningMode:
                return isAvailable(.cleaningMode)
            case .desktopPet:
                return isAvailable(.desktopPet)
            case .keepAwake:
                return isAvailable(.keepAwake)
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
        case .stickyNotes:
            return strings.featureHubNameStickyNotes
        case .dshWeb:
            return strings.featureHubNameDSHWeb
        case .networkDiagnostics:
            return strings.featureHubNameNetworkDiagnostics
        case .colorPicker:
            return strings.colorPickerName
        case .uninstaller:
            return strings.utilityUninstaller
        case .cleaner:
            return strings.utilityCleaner
        case .cleaningMode:
            return strings.featureHubNameCleaningMode
        case .desktopPet:
            return strings.featureHubNameDesktopPet
        case .keepAwake:
            return strings.featureHubNameKeepAwake
        }
    }

    /// 对应的功能目录项，用于复用图标 / 名称 / 描述，避免重复定义展示元数据。
    var feature: AppFeature {
        switch self {
        case .stickyNotes:
            return .stickyNotes
        case .dshWeb:
            return .dshWeb
        case .networkDiagnostics:
            return .networkDiagnostics
        case .colorPicker:
            return .colorPicker
        case .uninstaller:
            return .uninstaller
        case .cleaner:
            return .cleaner
        case .cleaningMode:
            return .cleaningMode
        case .desktopPet:
            return .desktopPet
        case .keepAwake:
            return .keepAwake
        }
    }

    /// 列表行展示的 SF Symbol。
    func symbolName() -> String {
        switch self {
        case .stickyNotes:
            return "note.text"
        case .dshWeb:
            return "server.rack"
        case .networkDiagnostics:
            return "globe"
        case .colorPicker:
            return "eyedropper"
        case .uninstaller:
            return "trash"
        case .cleaner:
            return "trash"
        case .cleaningMode:
            return "bubbles.and.sparkles"
        case .desktopPet:
            return "pawprint"
        case .keepAwake:
            return "moon.zzz.fill"
        }
    }

    /// 列表行图标徽章的主题高亮色。
    var tintColor: Color {
        switch self {
        case .stickyNotes:
            return .yellow
        case .dshWeb:
            return .purple
        case .networkDiagnostics:
            return .green
        case .colorPicker:
            return .orange
        case .uninstaller:
            return Color(red: 0.95, green: 0.35, blue: 0.32)
        case .cleaner:
            return .blue
        case .cleaningMode:
            return .mint
        case .desktopPet:
            return .brown
        case .keepAwake:
            return .purple
        }
    }

    /// 列表行展示的本地化名称（与 FeatureHub 统一）。
    func hubName(in strings: Strings) -> String { feature.hubName(in: strings) }

    /// 列表行展示的本地化描述。
    func hubDescription(in strings: Strings) -> String {
        switch self {
        case .stickyNotes:
            return strings.utilityStickyNotesSubtitle
        case .dshWeb:
            return strings.utilityDSHWebSubtitle
        case .networkDiagnostics:
            return strings.utilityNetworkDiagnosticsSubtitle
        case .colorPicker:
            return strings.utilityColorPickerSubtitle
        case .uninstaller:
            return strings.utilityUninstallerSubtitle
        case .cleaner:
            return strings.utilityCleanerSubtitle
        case .cleaningMode:
            return strings.utilityCleaningModeSubtitle
        case .desktopPet:
            return strings.utilityDesktopPetSubtitle
        case .keepAwake:
            return strings.utilityKeepAwakeSubtitle
        }
    }
}
