import Foundation

/// 保持唤醒已解析的配置快照。
struct KeepAwakeConfigurationSnapshot: Equatable {
    var defaultDuration: KeepAwakeDuration
    var batteryLimit: KeepAwakeBatteryLimit
    var autoStart: Bool
    var showCountdown: Bool
    var mouseJiggleEnabled: Bool
    var mouseJiggleInterval: KeepAwakePointerInterval
    var clamshellPreferred: Bool
    var shortcutEnabled: Bool
    var hotkey: HotkeyDefinition
}

/// 从注入的 UserDefaults 读取配置。
/// 键不存在 → 注册默认；键存在但非法 → 明确错误，不替换。
struct KeepAwakeConfiguration {
    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// 读取完整快照；任一非法值直接抛错。
    func load() throws -> KeepAwakeConfigurationSnapshot {
        KeepAwakeConfigurationSnapshot(
            defaultDuration: try duration(),
            batteryLimit: try batteryLimit(),
            autoStart: bool(for: UserDefaultsKeys.keepAwakeAutoStart, default: false),
            showCountdown: bool(for: UserDefaultsKeys.keepAwakeShowCountdown, default: false),
            mouseJiggleEnabled: bool(for: UserDefaultsKeys.keepAwakeMouseJiggleEnabled, default: false),
            mouseJiggleInterval: try pointerInterval(),
            clamshellPreferred: bool(for: UserDefaultsKeys.keepAwakeClamshellPreferred, default: false),
            shortcutEnabled: bool(for: UserDefaultsKeys.keepAwakeShortcutEnabled, default: true),
            hotkey: try hotkey()
        )
    }

    func duration() throws -> KeepAwakeDuration {
        if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes) == nil {
            return .indefinite
        }
        return try KeepAwakeDuration.parse(
            userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
        )
    }

    func batteryLimit() throws -> KeepAwakeBatteryLimit {
        if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent) == nil {
            return .percent10
        }
        return try KeepAwakeBatteryLimit.parse(
            userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent)
        )
    }

    func pointerInterval() throws -> KeepAwakePointerInterval {
        if userDefaults.object(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes) == nil {
            return .minutes5
        }
        return try KeepAwakePointerInterval.parse(
            userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
        )
    }

    func hotkey() throws -> HotkeyDefinition {
        let keyCodePresent = userDefaults.object(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode) != nil
        let modifiersPresent = userDefaults.object(forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers) != nil
        if !keyCodePresent && !modifiersPresent {
            return .defaultKeepAwake
        }
        // 任一键存在即按持久化值解析；缺失的一侧用 0，由业务后续校验。
        let keyCode = userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode)
        let modifiers = HotkeyModifiers(
            rawValue: userDefaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers)
        )
        return HotkeyDefinition(keyCode: keyCode, modifiers: modifiers)
    }

    private func bool(for key: String, default defaultValue: Bool) -> Bool {
        if userDefaults.object(forKey: key) == nil {
            return defaultValue
        }
        return userDefaults.bool(forKey: key)
    }
}
