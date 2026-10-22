import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 翻译工具全局快捷键（UserDefaults 为真源，KeyboardShortcuts 为运行时镜像）。
    static let translation = Self("translation")
}

// MARK: - KeyboardShortcuts 边界

/// KeyboardShortcuts 写界面：测试注入假实现，避免依赖全局注册状态。
protocol TranslationKeyboardShortcutsClient: AnyObject {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
}

final class LiveTranslationKeyboardShortcutsClient: TranslationKeyboardShortcutsClient {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name, action: action)
    }
}

// MARK: - 冲突检测

/// 翻译快捷键冲突来源：应用内已启用的快捷键与系统输入法键位。
///
/// 只做候选校验，不扩建通用快捷键注册中心；判定与既有录键组件的冲突语义一致。
struct TranslationHotkeyConflictChecker {
    private let userDefaults: UserDefaults
    private let systemHotkeys: () -> [SystemHotkeyReader.Hotkey]

    init(
        userDefaults: UserDefaults = .standard,
        systemHotkeys: @escaping () -> [SystemHotkeyReader.Hotkey] = {
            SystemHotkeyReader.readInputSourceHotkeys()
        }
    ) {
        self.userDefaults = userDefaults
        self.systemHotkeys = systemHotkeys
    }

    /// 返回与 `definition` 冲突的既有快捷键；无冲突返回 nil。
    func conflict(for definition: HotkeyDefinition) -> HotkeyDefinition? {
        let occupied = appHotkeys() + systemHotkeys().map(Self.definition(from:))
        return occupied.first { $0.keyCode == definition.keyCode && $0.modifiers == definition.modifiers }
    }

    /// 应用内各功能当前使用的快捷键（UserDefaults 真源）。
    private func appHotkeys() -> [HotkeyDefinition] {
        var hotkeys: [HotkeyDefinition] = []

        func append(_ keyCodeKey: String, _ modifiersKey: String) {
            guard let keyCode = userDefaults.object(forKey: keyCodeKey) as? Int,
                  let modifiers = userDefaults.object(forKey: modifiersKey) as? Int else {
                return
            }
            hotkeys.append(
                HotkeyDefinition(
                    keyCode: keyCode,
                    modifiers: HotkeyModifiers(rawValue: modifiers)
                )
            )
        }

        append(UserDefaultsKeys.clipboardHotkeyKeyCode, UserDefaultsKeys.clipboardHotkeyModifiers)
        append(UserDefaultsKeys.shelfHotkeyKeyCode, UserDefaultsKeys.shelfHotkeyModifiers)
        append(UserDefaultsKeys.stickyNoteHotkeyKeyCode, UserDefaultsKeys.stickyNoteHotkeyModifiers)
        append(
            UserDefaultsKeys.promptOptimizerHotkeyKeyCode,
            UserDefaultsKeys.promptOptimizerHotkeyModifiers
        )
        append(UserDefaultsKeys.keepAwakeHotkeyKeyCode, UserDefaultsKeys.keepAwakeHotkeyModifiers)
        // 截图 8 组快捷键。
        append(
            UserDefaultsKeys.screenshotHotkeyAllInOneKeyCode,
            UserDefaultsKeys.screenshotHotkeyAllInOneModifiers
        )
        append(UserDefaultsKeys.screenshotHotkeyCopyKeyCode, UserDefaultsKeys.screenshotHotkeyCopyModifiers)
        append(UserDefaultsKeys.screenshotHotkeyPinKeyCode, UserDefaultsKeys.screenshotHotkeyPinModifiers)
        append(
            UserDefaultsKeys.screenshotHotkeyFullscreenKeyCode,
            UserDefaultsKeys.screenshotHotkeyFullscreenModifiers
        )
        append(
            UserDefaultsKeys.screenshotHotkeyRecordKeyCode,
            UserDefaultsKeys.screenshotHotkeyRecordModifiers
        )
        append(
            UserDefaultsKeys.screenshotClotheslineHotkeyToggleKeyCode,
            UserDefaultsKeys.screenshotClotheslineHotkeyToggleModifiers
        )
        return hotkeys
    }

    /// 系统 plist 的修饰符位（Shift 1<<17 … Command 1<<20）转成本应用的高位定义。
    private static func definition(from systemHotkey: SystemHotkeyReader.Hotkey) -> HotkeyDefinition {
        var modifiers = HotkeyModifiers()
        let raw = systemHotkey.modifiers
        if raw & (1 << 17) != 0 { modifiers.insert(.shift) }
        if raw & (1 << 18) != 0 { modifiers.insert(.control) }
        if raw & (1 << 19) != 0 { modifiers.insert(.option) }
        if raw & (1 << 20) != 0 { modifiers.insert(.command) }
        return HotkeyDefinition(keyCode: systemHotkey.keyCode, modifiers: modifiers)
    }
}

// MARK: - 管理器

/// 快捷键冲突；UI 用本地化文案展示冲突键位。
enum TranslationHotkeyError: Error, Equatable {
    case conflict(HotkeyDefinition)
}

/// 翻译快捷键注册与触发：回调只负责把动作转给 `TranslationManager`。
///
/// 顺序约束由 manager 的 `handleHotkeyTrigger()` 保证（先取词后前置窗口）。
@MainActor
final class TranslationHotkeyManager {
    private let preferences: TranslationPreferences
    private let keyboardShortcuts: TranslationKeyboardShortcutsClient
    private let conflictProvider: (HotkeyDefinition) -> HotkeyDefinition?
    private let isFeatureAvailable: () -> Bool
    private let onTrigger: () -> Void

    private(set) var isListening = false
    private var registeredHandler = false

    init(
        preferences: TranslationPreferences,
        keyboardShortcuts: TranslationKeyboardShortcutsClient = LiveTranslationKeyboardShortcutsClient(),
        isFeatureAvailable: @escaping () -> Bool = { true },
        conflictProvider: ((HotkeyDefinition) -> HotkeyDefinition?)? = nil,
        onTrigger: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.keyboardShortcuts = keyboardShortcuts
        self.isFeatureAvailable = isFeatureAvailable
        self.conflictProvider = conflictProvider ?? { definition in
            TranslationHotkeyConflictChecker().conflict(for: definition)
        }
        self.onTrigger = onTrigger
    }

    // MARK: - 注册

    /// 注册快捷键；偏好禁用时不注册。幂等。
    func start() {
        guard isFeatureAvailable() else {
            stop()
            return
        }
        isListening = true
        applyShortcut()
        registerHandlerIfNeeded()
    }

    /// 移除当前快捷键的活动监听；保留用户偏好（重启或重新启用后可恢复）。
    func stop() {
        isListening = false
        keyboardShortcuts.setShortcut(nil, for: .translation)
    }

    /// availability 即启用：可用 → 注册，不可用 → 注销。
    func syncWithPreferences() {
        if isFeatureAvailable() {
            start()
        } else {
            stop()
        }
    }

    // MARK: - 修改

    /// 设置或禁用快捷键。
    ///
    /// 冲突时抛出且不写偏好、不替换当前绑定（保持上一份有效绑定）。
    func setHotkey(_ definition: HotkeyDefinition?) throws {
        if let definition, let conflict = conflictProvider(definition) {
            throw TranslationHotkeyError.conflict(conflict)
        }
        preferences.setHotkey(definition)
        if isListening {
            applyShortcut()
        }
    }

    /// 录键组件直接写 UserDefaults 后同步内存态并重新注册。
    func reloadHotkey() {
        preferences.reloadHotkey()
        if isListening {
            applyShortcut()
        }
    }

    // MARK: - 触发

    func handleHotkey() {
        guard isFeatureAvailable() else { return }
        onTrigger()
    }

    // MARK: - 私有

    private func applyShortcut() {
        keyboardShortcuts.setShortcut(preferences.hotkey?.keyboardShortcut, for: .translation)
    }

    private func registerHandlerIfNeeded() {
        guard !registeredHandler else { return }
        keyboardShortcuts.onKeyUp(for: .translation) { [weak self] in
            if Thread.isMainThread {
                self?.handleHotkey()
            } else {
                Task { @MainActor in
                    self?.handleHotkey()
                }
            }
        }
        registeredHandler = true
    }
}
