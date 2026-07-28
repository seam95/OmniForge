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
    case keepAwake
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
            case .keepAwake:
                return isAvailable(.keepAwake)
            case .cleaner:
                return isAvailable(.cleaner)
            case .uninstaller:
                return isAvailable(.uninstaller)
            }
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

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .inputMethod: return "keyboard"
        case .clipboard: return "doc.on.doc"
        case .shelf: return "tray.full"
        case .screenshot: return "camera.viewfinder"
        case .mouse: return "computermouse"
        case .performance: return "gauge.with.dots.needle.33percent"
        case .keepAwake: return "moon.zzz.fill"
        case .cleaner: return "sparkles"
        case .uninstaller: return "trash"
        case .features: return "puzzlepiece.extension"
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
        case .keepAwake: return strings.featureHubNameKeepAwake
        case .cleaner: return strings.cleanerName
        case .uninstaller: return strings.uninstallerName
        case .features: return strings.settingsTabFeatures
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
