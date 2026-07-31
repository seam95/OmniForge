import AppKit
import Carbon
import KeyboardShortcuts

/// 快捷键修饰符（与 NSEvent/Carbon 双向桥接）。
/// 被 Clipboard / Shelf / KeepAwake 共用，迁移自 ClipboardHotkeyManager。
struct HotkeyModifiers: OptionSet, Codable, Equatable {
    let rawValue: Int

    static let command = HotkeyModifiers(rawValue: 1 << 0)
    static let shift = HotkeyModifiers(rawValue: 1 << 1)
    static let option = HotkeyModifiers(rawValue: 1 << 2)
    static let control = HotkeyModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension HotkeyModifiers {
    init(eventFlags: NSEvent.ModifierFlags) {
        var modifiers = HotkeyModifiers()
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    var symbolString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    init(carbonModifiers: Int) {
        var modifiers = HotkeyModifiers()
        if carbonModifiers & Int(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonModifiers & Int(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbonModifiers & Int(optionKey) != 0 { modifiers.insert(.option) }
        if carbonModifiers & Int(controlKey) != 0 { modifiers.insert(.control) }
        self = modifiers
    }

    var carbonModifiers: Int {
        Int(carbonFlags)
    }
}

/// 快捷键定义（keycode + modifiers + Carbon flags + 显示与 KBS bridge）。
/// 被 Clipboard / Shelf / KeepAwake 共用，迁移自 ClipboardHotkeyManager。
struct HotkeyDefinition: Equatable, Codable {
    let keyCode: Int
    let modifiers: HotkeyModifiers

    static let defaultClipboard = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_V),
        modifiers: [.command, .shift]
    )
    static let defaultShelf = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_D),
        modifiers: [.control, .option, .command]
    )
    /// 保持唤醒默认快捷键：⌃⌥⌘K
    static let defaultKeepAwake = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_K),
        modifiers: [.control, .option, .command]
    )

    // 截图默认快捷键：统一 ⌃⌥⌘ + 数字，避开 clipboard(⌘⇧V) / shelf(⌃⌥⌘D) / keepAwake(⌃⌥⌘K)
    // 顺序：全能1 / 复制2 / 贴图3 / 全屏4 / 录屏5（仅影响未自定义用户的注册默认）
    static let defaultScreenshotAllInOne = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_1),
        modifiers: [.control, .option, .command]
    )
    /// 截图并复制默认快捷键：⌃⌥⌘2
    static let defaultScreenshotCopy = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_2),
        modifiers: [.control, .option, .command]
    )
    /// 截图并贴图默认快捷键：⌃⌥⌘3
    static let defaultScreenshotPin = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_3),
        modifiers: [.control, .option, .command]
    )
    /// 全屏截图默认快捷键：⌃⌥⌘4（原 2）
    static let defaultScreenshotFullscreen = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_4),
        modifiers: [.control, .option, .command]
    )
    /// 录屏框选默认快捷键：⌃⌥⌘5（原 3）
    static let defaultScreenshotRecord = HotkeyDefinition(
        keyCode: Int(kVK_ANSI_5),
        modifiers: [.control, .option, .command]
    )

    init(keyCode: Int, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let keyCode = Int(event.keyCode)
        guard !HotkeyDefinition.isModifierKey(keyCode) else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = HotkeyModifiers(eventFlags: event.modifierFlags)
    }

    var displayString: String {
        modifiers.symbolString + HotkeyDefinition.keyLabel(for: keyCode)
    }

    var keyboardShortcut: KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(
            carbonKeyCode: keyCode,
            carbonModifiers: modifiers.carbonModifiers
        )
    }

    init?(shortcut: KeyboardShortcuts.Shortcut?) {
        guard let shortcut else { return nil }
        self.init(
            keyCode: shortcut.carbonKeyCode,
            modifiers: HotkeyModifiers(carbonModifiers: shortcut.carbonModifiers)
        )
    }

    private static func isModifierKey(_ keyCode: Int) -> Bool {
        let modifierKeyCodes: Set<Int> = [
            Int(kVK_Command),
            Int(kVK_RightCommand),
            Int(kVK_Shift),
            Int(kVK_RightShift),
            Int(kVK_Option),
            Int(kVK_RightOption),
            Int(kVK_Control),
            Int(kVK_RightControl),
            Int(kVK_Function)
        ]
        return modifierKeyCodes.contains(keyCode)
    }

    private static func keyLabel(for keyCode: Int) -> String {
        if let label = keyLabels[keyCode] {
            return label
        }
        return "Key\(keyCode)"
    }

    private static let keyLabels: [Int: String] = [
        Int(kVK_ANSI_A): "A",
        Int(kVK_ANSI_B): "B",
        Int(kVK_ANSI_C): "C",
        Int(kVK_ANSI_D): "D",
        Int(kVK_ANSI_E): "E",
        Int(kVK_ANSI_F): "F",
        Int(kVK_ANSI_G): "G",
        Int(kVK_ANSI_H): "H",
        Int(kVK_ANSI_I): "I",
        Int(kVK_ANSI_J): "J",
        Int(kVK_ANSI_K): "K",
        Int(kVK_ANSI_L): "L",
        Int(kVK_ANSI_M): "M",
        Int(kVK_ANSI_N): "N",
        Int(kVK_ANSI_O): "O",
        Int(kVK_ANSI_P): "P",
        Int(kVK_ANSI_Q): "Q",
        Int(kVK_ANSI_R): "R",
        Int(kVK_ANSI_S): "S",
        Int(kVK_ANSI_T): "T",
        Int(kVK_ANSI_U): "U",
        Int(kVK_ANSI_V): "V",
        Int(kVK_ANSI_W): "W",
        Int(kVK_ANSI_X): "X",
        Int(kVK_ANSI_Y): "Y",
        Int(kVK_ANSI_Z): "Z",
        Int(kVK_ANSI_0): "0",
        Int(kVK_ANSI_1): "1",
        Int(kVK_ANSI_2): "2",
        Int(kVK_ANSI_3): "3",
        Int(kVK_ANSI_4): "4",
        Int(kVK_ANSI_5): "5",
        Int(kVK_ANSI_6): "6",
        Int(kVK_ANSI_7): "7",
        Int(kVK_ANSI_8): "8",
        Int(kVK_ANSI_9): "9",
        Int(kVK_Space): "Space",
        Int(kVK_Return): "Return",
        Int(kVK_Delete): "Delete",
        Int(kVK_Tab): "Tab",
        Int(kVK_Escape): "Esc",
        Int(kVK_UpArrow): "↑",
        Int(kVK_DownArrow): "↓",
        Int(kVK_LeftArrow): "←",
        Int(kVK_RightArrow): "→",
        Int(kVK_F1): "F1",
        Int(kVK_F2): "F2",
        Int(kVK_F3): "F3",
        Int(kVK_F4): "F4",
        Int(kVK_F5): "F5",
        Int(kVK_F6): "F6",
        Int(kVK_F7): "F7",
        Int(kVK_F8): "F8",
        Int(kVK_F9): "F9",
        Int(kVK_F10): "F10",
        Int(kVK_F11): "F11",
        Int(kVK_F12): "F12"
    ]
}
