import Foundation

/// 特性目录 — 声明式描述所有可安装/卸载的特性。
/// rawValue 是持久化到 UserDefaults 的稳定标识，只能新增不能重命名。
enum AppFeature: String, CaseIterable {
    case inputLock
    case clipboardHistory
    case quickPhrase
    case systemMonitor
    case tokenUsage
    case networkDiagnostics
    case dshWeb
    case shelf
    case launchAtLogin
    case cleaner
    case uninstaller
    case colorPicker
    // 鼠标与触控板
    case scrollInverter
    case smoothScroll
    case mouseNavigation
    case dockClick
    case keepAwake
    case screenshot
    case providerSwitch
    case stickyNotes
    case cleaningMode

    /// 设置「鼠标」分区与相关入口共用的功能集合。
    static let mouseFeatures: [AppFeature] = [
        .scrollInverter,
        .smoothScroll,
        .mouseNavigation,
        .dockClick,
    ]
}

/// 特性分组，用于 Settings UI 展示；case 顺序即侧栏与功能目录的分组展示顺序。
enum FeatureGroup: String, CaseIterable {
    case input        // 输入法相关
    case clipboard    // 剪贴板与快捷短语
    case monitor      // 系统监控
    case ai           // AI CLI 供应商切换
    case productivity // 生产力工具
    case system       // 系统集成
    case mouse        // 鼠标与触控板
    case energy       // 电源与唤醒
    case capture      // 截图与捕获
}

/// 权限用途：区分“可能使用 / 已配置 / 可选 / 当前未使用”
enum FeaturePermissionUsage: String, Equatable {
    case required
    case configured
    case optional
    case inactive
}

/// 系统权限类型
enum AppPermission: String, CaseIterable {
    case accessibility
    case inputMonitoring
    case notifications
    case fullDiskAccess
    case screenRecording
}

extension AppFeature {
    /// 特性所属分组
    var group: FeatureGroup {
        switch self {
        case .inputLock: return .input
        case .clipboardHistory, .quickPhrase: return .clipboard
        case .systemMonitor, .tokenUsage: return .monitor
        case .shelf: return .productivity
        case .launchAtLogin: return .system
        case .cleaner, .uninstaller, .colorPicker, .networkDiagnostics, .dshWeb: return .productivity
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick: return .mouse
        case .keepAwake: return .energy
        case .screenshot: return .capture
        case .providerSwitch: return .ai
        case .stickyNotes, .cleaningMode: return .productivity
        }
    }

    /// 持久化 availability 状态的 UserDefaults 键
    var availabilityKey: String { "featureAvailable.\(rawValue)" }

    // availability 读取唯一入口：`FeatureRuntime.isAvailable` / `FeatureAvailabilityStoring`。
    // 禁止在此对 UserDefaults.standard 直读。

    /// 特性自身的 enable 键列表 — 任一为 true 即表示该特性已启用。
    /// 空列表表示按需触发型特性（面板/快捷键驱动），available 即等于 engaged。
    var enabledKeys: [String] {
        switch self {
        case .inputLock: return [UserDefaultsKeys.isLocked]
        case .clipboardHistory: return [UserDefaultsKeys.clipboardFeatureEnabled]
        case .quickPhrase: return []
        case .systemMonitor, .networkDiagnostics, .tokenUsage: return []
        case .shelf: return [UserDefaultsKeys.shelfEnabled]
        case .launchAtLogin: return []
        case .cleaner, .uninstaller, .colorPicker, .dshWeb: return []
        case .scrollInverter: return [UserDefaultsKeys.scrollInverterEnabled]
        case .smoothScroll: return [UserDefaultsKeys.smoothScrollEnabled]
        case .mouseNavigation: return [UserDefaultsKeys.mouseNavigationEnabled]
        case .dockClick: return [UserDefaultsKeys.dockClickMinimize, UserDefaultsKeys.dockClickCycleWindows]
        case .keepAwake: return []
        case .screenshot: return [UserDefaultsKeys.screenshotEnabled]
        case .providerSwitch: return []
        case .stickyNotes: return []
        case .cleaningMode: return []
        }
    }

    /// 该特性可能声明的系统权限（静态目录；不等于“正在使用”）
    var possiblePermissions: [AppPermission] {
        switch self {
        case .inputLock: return [.accessibility]
        case .clipboardHistory: return []
        case .quickPhrase: return []
        case .systemMonitor: return [.notifications]
        case .tokenUsage: return [.notifications]
        case .networkDiagnostics, .dshWeb: return []
        case .shelf: return []
        case .launchAtLogin: return []
        case .cleaner, .uninstaller: return [.fullDiskAccess]
        case .colorPicker: return []
        case .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick: return [.accessibility]
        case .keepAwake: return [.accessibility, .notifications]
        case .screenshot: return [.screenRecording]
        case .providerSwitch: return []
        case .stickyNotes: return [.notifications]
        case .cleaningMode: return [.accessibility]
        }
    }

    /// 兼容旧调用：等同于静态 possiblePermissions
    var permissions: [AppPermission] { possiblePermissions }

    /// 运行时权限用途。不能把 available 直接等同于“正在使用权限”。
    func permissionUsage(
        for permission: AppPermission,
        mouseJiggleEnabled: Bool = false
    ) -> FeaturePermissionUsage? {
        guard possiblePermissions.contains(permission) else { return nil }
        switch self {
        case .keepAwake:
            switch permission {
            case .accessibility:
                // 仅指针微动偏好开启时为 configured；普通会话不需要辅助功能。
                return mouseJiggleEnabled ? .configured : .inactive
            case .notifications:
                return .optional
            case .inputMonitoring, .fullDiskAccess, .screenRecording:
                return nil
            }
        case .inputLock, .scrollInverter, .smoothScroll, .mouseNavigation, .dockClick:
            return permission == .accessibility ? .required : nil
        case .systemMonitor, .tokenUsage:
            return permission == .notifications ? .optional : nil
        case .cleaner, .uninstaller:
            return permission == .fullDiskAccess ? .required : nil
        case .colorPicker, .networkDiagnostics, .dshWeb:
            return nil
        case .screenshot:
            return permission == .screenRecording ? .required : nil
        case .stickyNotes:
            // 提醒走系统通知；未授权时提醒仍可设置（仅无横幅），故为可选。
            return permission == .notifications ? .optional : nil
        case .cleaningMode:
            return permission == .accessibility ? .required : nil
        case .providerSwitch:
            return nil
        case .clipboardHistory, .quickPhrase, .shelf, .launchAtLogin:
            return nil
        }
    }

    /// 注册默认值：所有特性默认 available，升级对现有用户无感
    static var availabilityDefaults: [String: Any] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.availabilityKey, true) })
    }

    /// 特性在 Hub 中展示的 SF Symbol
    var symbolName: String {
        switch self {
        case .inputLock: return "lock.fill"
        case .clipboardHistory: return "doc.on.clipboard"
        case .quickPhrase: return "text.bubble"
        case .systemMonitor: return "chart.bar"
        case .tokenUsage: return "chart.line.uptrend.xyaxis"
        case .networkDiagnostics: return "network"
        case .shelf: return "tray.full"
        case .launchAtLogin: return "power"
        case .cleaner: return "sparkles"
        case .uninstaller: return "trash"
        case .colorPicker: return "eyedropper"
        case .dshWeb: return "globe"
        case .scrollInverter: return "arrow.up.arrow.down"
        case .smoothScroll: return "cursorarrow.motionlines"
        case .mouseNavigation: return "arrow.left.arrow.right"
        case .dockClick: return "dock.arrow.down.rectangle"
        case .keepAwake: return "moon.zzz.fill"
        case .screenshot: return "camera.viewfinder"
        case .providerSwitch: return "arrow.triangle.swap"
        case .stickyNotes: return "note.text"
        case .cleaningMode: return "bubbles.and.sparkles"
        }
    }

    /// 特性在 Hub 中的本地化名称
    func hubName(in strings: Strings) -> String {
        switch self {
        case .inputLock: return strings.featureHubNameInputLock
        case .clipboardHistory: return strings.featureHubNameClipboardHistory
        case .quickPhrase: return strings.featureHubNameQuickPhrase
        case .systemMonitor: return strings.featureHubNameSystemMonitor
        case .tokenUsage: return strings.featureHubNameTokenUsage
        case .networkDiagnostics: return strings.featureHubNameNetworkDiagnostics
        case .shelf: return strings.featureHubNameShelf
        case .launchAtLogin: return strings.featureHubNameLaunchAtLogin
        case .cleaner: return strings.cleanerName
        case .uninstaller: return strings.uninstallerName
        case .colorPicker: return strings.colorPickerName
        case .dshWeb: return strings.featureHubNameDSHWeb
        case .scrollInverter: return strings.featureHubNameScrollInverter
        case .smoothScroll: return strings.featureHubNameSmoothScroll
        case .mouseNavigation: return strings.featureHubNameMouseNavigation
        case .dockClick: return strings.featureHubNameDockClick
        case .keepAwake: return strings.featureHubNameKeepAwake
        case .screenshot: return strings.featureHubNameScreenshot
        case .providerSwitch: return strings.featureHubNameProviderSwitch
        case .stickyNotes: return strings.featureHubNameStickyNotes
        case .cleaningMode: return strings.featureHubNameCleaningMode
        }
    }

    /// 特性在 Hub 中的本地化描述
    func hubDescription(in strings: Strings) -> String {
        switch self {
        case .inputLock: return strings.featureHubDescInputLock
        case .clipboardHistory: return strings.featureHubDescClipboardHistory
        case .quickPhrase: return strings.featureHubDescQuickPhrase
        case .systemMonitor: return strings.featureHubDescSystemMonitor
        case .tokenUsage: return strings.featureHubDescTokenUsage
        case .networkDiagnostics: return strings.featureHubDescNetworkDiagnostics
        case .shelf: return strings.featureHubDescShelf
        case .launchAtLogin: return strings.featureHubDescLaunchAtLogin
        case .cleaner: return strings.cleanerIntroCaption
        case .uninstaller: return strings.uninstallerEnableCaption
        case .colorPicker: return strings.colorPickerDescription
        case .dshWeb: return strings.featureHubDescDSHWeb
        case .scrollInverter: return strings.featureHubDescScrollInverter
        case .smoothScroll: return strings.featureHubDescSmoothScroll
        case .mouseNavigation: return strings.featureHubDescMouseNavigation
        case .dockClick: return strings.featureHubDescDockClick
        case .keepAwake: return strings.featureHubDescKeepAwake
        case .screenshot: return strings.featureHubDescScreenshot
        case .providerSwitch: return strings.featureHubDescProviderSwitch
        case .stickyNotes: return strings.featureHubDescStickyNotes
        case .cleaningMode: return strings.featureHubDescCleaningMode
        }
    }

}

extension FeatureGroup {
    /// 分组在 Hub 中的本地化标题
    func hubTitle(in strings: Strings) -> String {
        switch self {
        case .input: return strings.featureHubGroupInput
        case .clipboard: return strings.featureHubGroupClipboard
        case .monitor: return strings.featureHubGroupMonitor
        case .productivity: return strings.featureHubGroupProductivity
        case .system: return strings.featureHubGroupSystem
        case .mouse: return strings.featureHubGroupMouse
        case .energy: return strings.featureHubGroupEnergy
        case .capture: return strings.featureHubGroupCapture
        case .ai: return strings.featureHubGroupAI
        }
    }

    /// 按分组返回该组下的所有特性（按声明顺序）
    static func features(in group: FeatureGroup) -> [AppFeature] {
        AppFeature.allCases.filter { $0.group == group }
    }
}

extension AppPermission {
    /// 权限在 Hub 中展示的 SF Symbol
    var symbolName: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .notifications: return "bell.badge"
        case .fullDiskAccess: return "externaldrive.fill.badge.checkmark"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    /// 权限在 Hub 中的本地化名称
    func hubName(in strings: Strings) -> String {
        switch self {
        case .accessibility: return strings.featureHubPermNameAccessibility
        case .inputMonitoring: return strings.featureHubPermNameInputMonitoring
        case .notifications: return strings.featureHubPermNameNotifications
        case .fullDiskAccess: return strings.featureHubPermNameFullDiskAccess
        case .screenRecording: return strings.featureHubPermNameScreenRecording
        }
    }

    /// 权限在 Hub 中的本地化描述
    func hubDescription(in strings: Strings) -> String {
        switch self {
        case .accessibility: return strings.featureHubPermDescAccessibility
        case .inputMonitoring: return strings.featureHubPermDescInputMonitoring
        case .notifications: return strings.featureHubPermDescNotifications
        case .fullDiskAccess: return strings.featureHubPermDescFullDiskAccess
        case .screenRecording: return strings.featureHubPermDescScreenRecording
        }
    }
}
