import SwiftUI

/// 设置侧边栏导航项（顶层信息架构）。
enum SettingsToolbarTab: String, CaseIterable, Identifiable {
    case general
    case features
    case inputMethod
    case clipboard
    case shelf
    case screenshot
    case mouse
    case performance
    case tokenUsage
    case keepAwake
    case providerSwitch
    case cleaner
    case uninstaller

    static func visibleCases(isAvailable: (AppFeature) -> Bool) -> [SettingsToolbarTab] {
        allCases.filter { tab in
            switch tab {
            case .general, .features:
                return true
            case .inputMethod:
                return isAvailable(.inputLock)
            case .clipboard:
                return isAvailable(.clipboardHistory)
            case .shelf:
                return isAvailable(.shelf)
            case .screenshot:
                return isAvailable(.screenshot)
            case .mouse:
                return AppFeature.mouseFeatures.contains(where: isAvailable)
            case .performance:
                return isAvailable(.systemMonitor)
            case .tokenUsage:
                return isAvailable(.tokenUsage)
            case .keepAwake:
                return isAvailable(.keepAwake)
            case .providerSwitch:
                return isAvailable(.providerSwitch)
            case .cleaner:
                return isAvailable(.cleaner)
            case .uninstaller:
                return isAvailable(.uninstaller)
            }
        }
    }

    static func visibleSections(isAvailable: (AppFeature) -> Bool) -> [SettingsSidebarSection] {
        let visibleTabs = visibleCases(isAvailable: isAvailable)
        return FeatureGroup.allCases.compactMap { group in
            let tabs = visibleTabs.filter { $0.sidebarGroup == group }
            guard !tabs.isEmpty else { return nil }
            return SettingsSidebarSection(group: group, tabs: tabs)
        }
    }

    static func resolvedSelection(
        _ selection: SettingsToolbarTab?,
        in visibleCases: [SettingsToolbarTab]
    ) -> SettingsToolbarTab? {
        guard let first = visibleCases.first else { return nil }
        guard let selection, visibleCases.contains(selection) else { return first }
        return selection
    }

    var id: String { rawValue }

    var sidebarGroup: FeatureGroup? {
        switch self {
        case .general, .features:
            return nil
        case .inputMethod:
            return .input
        case .clipboard:
            return .clipboard
        case .shelf, .cleaner, .uninstaller:
            return .productivity
        case .screenshot:
            return .capture
        case .mouse:
            return .mouse
        case .performance, .tokenUsage:
            return .monitor
        case .keepAwake:
            return .energy
        case .providerSwitch:
            return .ai
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .inputMethod: return "keyboard"
        case .clipboard: return "doc.on.doc"
        case .shelf: return "tray.full"
        case .screenshot: return "camera.viewfinder"
        case .mouse: return "computermouse"
        case .performance: return "gauge.with.dots.needle.33percent"
        case .tokenUsage: return "chart.line.uptrend.xyaxis"
        case .keepAwake: return "moon.zzz.fill"
        case .providerSwitch: return "arrow.triangle.swap"
        case .cleaner: return "sparkles"
        case .uninstaller: return "trash"
        case .features: return "puzzlepiece.extension"
        }
    }

    /// 侧栏图标徽章底色（系统设置风格：彩色圆角方块 + 白色符号）。
    var sidebarTint: Color {
        switch self {
        case .general: return .gray
        case .features: return .purple
        case .inputMethod: return .blue
        case .clipboard: return .green
        case .shelf: return .orange
        case .cleaner: return .mint
        case .uninstaller: return .red
        case .screenshot: return .teal
        case .mouse: return .indigo
        case .performance: return .green
        case .tokenUsage: return .orange
        case .keepAwake: return .purple
        case .providerSwitch: return .blue
        }
    }

    func title(in strings: Strings) -> String {
        switch self {
        case .general: return strings.settingsTabGeneral
        case .inputMethod: return strings.settingsTabInputMethod
        case .clipboard: return strings.settingsTabClipboard
        case .shelf: return strings.settingsTabShelf
        case .screenshot: return strings.settingsTabScreenshot
        case .mouse: return strings.settingsTabMouse
        case .performance: return strings.settingsTabPerformance
        case .tokenUsage: return strings.settingsTabTokenUsage
        case .keepAwake: return strings.featureHubNameKeepAwake
        case .providerSwitch: return strings.settingsTabProviderSwitch
        case .cleaner: return strings.cleanerName
        case .uninstaller: return strings.uninstallerName
        case .features: return strings.settingsTabFeatures
        }
    }
}

struct SettingsSidebarSection: Identifiable, Equatable {
    let group: FeatureGroup
    let tabs: [SettingsToolbarTab]

    var id: FeatureGroup { group }

    func title(in strings: Strings) -> String {
        group.hubTitle(in: strings)
    }
}

/// Token 用量设置页内部分段（通用 / 提供商 / 告警）。
/// 4 家需凭证的提供商（DeepSeek / Trae CN / OpenCode / 方舟）配置入口并入「提供商」页展开卡。
enum TokenUsageSettingsSection: String, CaseIterable, Identifiable {
    case general
    case providers
    case alerts

    var id: String { rawValue }

    func title(in strings: Strings) -> String {
        switch self {
        case .general: return strings.tokenSettingsGenericSection
        case .providers: return strings.tokenSettingsProvidersSection
        case .alerts: return strings.tokenSettingsAlertsSection
        }
    }
}

/// 性能页内部分段（监控 / 菜单栏 / 告警）。
enum PerformanceSettingsSection: String, CaseIterable, Identifiable {
    case monitor
    case menuBar
    case alerts

    var id: String { rawValue }

    func title(in strings: Strings) -> String {
        switch self {
        case .monitor: return strings.settingsTabMonitor
        case .menuBar: return strings.settingsTabMenuBar
        case .alerts: return strings.settingsTabAlerts
        }
    }
}
