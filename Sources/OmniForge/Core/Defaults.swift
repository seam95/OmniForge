import Foundation

/// 集中注册 UserDefaults 默认值，应用启动时调用一次。
/// registerDomain 只在键不存在时写入，不会覆盖用户已有值。
enum Defaults {
    /// 在指定 UserDefaults 实例上注册默认值
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: mergedDefaults)
    }

    /// 合并后的默认值表（测试与诊断只读；`register` 的唯一来源）。
    static var registrationValues: [String: Any] { mergedDefaults }

    /// 合并所有模块的默认值
    private static var mergedDefaults: [String: Any] {
        AppFeature.availabilityDefaults
            .merging(onboardingDefaults, uniquingKeysWith: { _, new in new })
            .merging(shelfDefaults, uniquingKeysWith: { _, new in new })
            .merging(cleanerDefaults, uniquingKeysWith: { _, new in new })
            .merging(mouseDefaults, uniquingKeysWith: { _, new in new })
            .merging(utilityDefaults, uniquingKeysWith: { _, new in new })
            .merging(controlCenterDefaults, uniquingKeysWith: { _, new in new })
            .merging(keepAwakeDefaults, uniquingKeysWith: { _, new in new })
            .merging(screenshotDefaults, uniquingKeysWith: { _, new in new })
            .merging(networkDiagnosticsDefaults, uniquingKeysWith: { _, new in new })
    }

    /// Onboarding 相关默认值
    private static var onboardingDefaults: [String: Any] {
        [
            UserDefaultsKeys.hasOnboarded: false,
            UserDefaultsKeys.onboardingCompletedVersion: "",
            UserDefaultsKeys.onboardingCurrentStep: 0,
            UserDefaultsKeys.lastWhatsNewVersion: "",
        ]
    }

    private static var shelfDefaults: [String: Any] {
        [
            UserDefaultsKeys.shelfEnabled: false,
            UserDefaultsKeys.shelfShortcutEnabled: true,
            UserDefaultsKeys.shelfHotkeyKeyCode: HotkeyDefinition.defaultShelf.keyCode,
            UserDefaultsKeys.shelfHotkeyModifiers: HotkeyDefinition.defaultShelf.modifiers.rawValue,
            UserDefaultsKeys.shelfShakeToOpen: true,
            UserDefaultsKeys.shelfDropZoneEnabled: true,
            UserDefaultsKeys.shelfCloseAfterDrop: false,
            UserDefaultsKeys.shelfRemoveAfterDrop: true,
            UserDefaultsKeys.shelfAutomaticExclusions: [String](),
        ]
    }

    /// Cleaner 调度相关默认值
    private static var cleanerDefaults: [String: Any] {
        [
            UserDefaultsKeys.cleanerScheduleFrequency: "off",
            UserDefaultsKeys.cleanerScheduleHour: 9,
            UserDefaultsKeys.cleanerScheduleMinute: 0,
            UserDefaultsKeys.cleanerScheduleWeekday: 2,
            UserDefaultsKeys.cleanerScheduleNotify: true,
            UserDefaultsKeys.cleanerLastAutoRun: 0.0,
            UserDefaultsKeys.cleanerLastAutoFreed: 0,
        ]
    }

    /// 鼠标子功能默认关闭。
    private static var mouseDefaults: [String: Any] {
        [
            UserDefaultsKeys.scrollInverterEnabled: false,
            UserDefaultsKeys.smoothScrollEnabled: false,
            UserDefaultsKeys.smoothScrollStep: SmoothScrollSupport.defaultStep,
            UserDefaultsKeys.mouseNavigationEnabled: false,
            UserDefaultsKeys.dockClickMinimize: false,
            UserDefaultsKeys.dockClickCycleWindows: false,
        ]
    }

    private static var utilityDefaults: [String: Any] {
        [UserDefaultsKeys.lastUtilityTool: UtilityTool.cleaner.rawValue]
    }

    private static var controlCenterDefaults: [String: Any] {
        [UserDefaultsKeys.lastControlCenterPanel: MenuPanel.systemMonitor.rawValue]
    }

    /// 保持唤醒偏好默认值；会话活动状态不得写入 UserDefaults。
    private static var keepAwakeDefaults: [String: Any] {
        [
            UserDefaultsKeys.keepAwakeDefaultDurationMinutes: KeepAwakeDuration.indefinite.minutes,
            UserDefaultsKeys.keepAwakeBatteryLimitPercent: KeepAwakeBatteryLimit.percent10.percent,
            UserDefaultsKeys.keepAwakeAutoStart: false,
            UserDefaultsKeys.keepAwakeShowCountdown: false,
            UserDefaultsKeys.keepAwakeMouseJiggleEnabled: false,
            UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes: KeepAwakePointerInterval.minutes5.minutes,
            UserDefaultsKeys.keepAwakeClamshellPreferred: false,
            UserDefaultsKeys.keepAwakeShortcutEnabled: true,
            UserDefaultsKeys.keepAwakeHotkeyKeyCode: HotkeyDefinition.defaultKeepAwake.keyCode,
            UserDefaultsKeys.keepAwakeHotkeyModifiers: HotkeyDefinition.defaultKeepAwake.modifiers.rawValue,
        ]
    }

    /// 截图偏好默认值（决策 8.3-5 / 8.4-12）；真实编码与写盘归 T3。
    private static var screenshotDefaults: [String: Any] {
        [
            UserDefaultsKeys.screenshotEnabled: false,
            UserDefaultsKeys.screenshotSaveDirectoryPath: ScreenshotOutputConfiguration.defaultDirectoryPath,
            UserDefaultsKeys.screenshotFileNamePrefix: ScreenshotOutputConfiguration.defaultPrefix,
            UserDefaultsKeys.screenshotHotkeyAllInOneKeyCode: HotkeyDefinition.defaultScreenshotAllInOne.keyCode,
            UserDefaultsKeys.screenshotHotkeyAllInOneModifiers: HotkeyDefinition.defaultScreenshotAllInOne.modifiers.rawValue,
            UserDefaultsKeys.screenshotHotkeyCopyKeyCode: HotkeyDefinition.defaultScreenshotCopy.keyCode,
            UserDefaultsKeys.screenshotHotkeyCopyModifiers: HotkeyDefinition.defaultScreenshotCopy.modifiers.rawValue,
            UserDefaultsKeys.screenshotHotkeyPinKeyCode: HotkeyDefinition.defaultScreenshotPin.keyCode,
            UserDefaultsKeys.screenshotHotkeyPinModifiers: HotkeyDefinition.defaultScreenshotPin.modifiers.rawValue,
            UserDefaultsKeys.screenshotHotkeyFullscreenKeyCode: HotkeyDefinition.defaultScreenshotFullscreen.keyCode,
            UserDefaultsKeys.screenshotHotkeyFullscreenModifiers: HotkeyDefinition.defaultScreenshotFullscreen.modifiers.rawValue,
            UserDefaultsKeys.screenshotHotkeyRecordKeyCode: HotkeyDefinition.defaultScreenshotRecord.keyCode,
            UserDefaultsKeys.screenshotHotkeyRecordModifiers: HotkeyDefinition.defaultScreenshotRecord.modifiers.rawValue,
            UserDefaultsKeys.screenshotRecentEmojis: [String](),
            UserDefaultsKeys.recordingSaveDirectoryPath: RecordingOutputConfiguration.defaultDirectoryPath,
            UserDefaultsKeys.recordingSavePreference: RecordingOutputConfiguration.defaultSavePreference.rawValue,
            UserDefaultsKeys.recordingLastManualFormat: RecordingOutputConfiguration.defaultManualFormat.rawValue,
        ]
    }

    /// 网络诊断分段默认值；与 NetworkSegment.network rawValue 对齐。
    private static var networkDiagnosticsDefaults: [String: Any] {
        [
            UserDefaultsKeys.networkDiagnosticsSegment: "network",
        ]
    }

    /// Trims, drops empties, and de-duplicates bundle identifiers while preserving order.
    static func sanitizedBundleIdentifierList(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in bundleIDs {
            let bundleID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            result.append(bundleID)
        }
        return result
    }

    // MARK: - 最近 emoji

    /// 读取最近 emoji（未注册或为空时返回空数组，由调用方回退默认列表）。
    static func recentEmojis(in defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: UserDefaultsKeys.screenshotRecentEmojis) as? [String]) ?? []
    }

    /// 写入最近 emoji，并截断到指定上限。
    static func setRecentEmojis(_ emojis: [String], limit: Int = 10,
                                in defaults: UserDefaults = .standard) {
        defaults.set(Array(emojis.prefix(limit)), forKey: UserDefaultsKeys.screenshotRecentEmojis)
    }
}
