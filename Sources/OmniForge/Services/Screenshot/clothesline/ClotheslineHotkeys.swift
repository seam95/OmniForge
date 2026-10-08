import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let clotheslineToggle = Self("clotheslineToggle")
    static let clotheslineHang = Self("clotheslineHang")
}

/// 晾衣绳热键条目：显示/隐藏绳子（默认 ⌃⌥⌘T）与截图挂绳（默认未绑定）。
/// 与 ScreenshotHotkeyEntry 同构；已核实 ⌃⌥⌘T 与现有默认键位
/// （⌘⇧V / ⌃⌥⌘D / ⌃⌥⌘K / ⌃⌥⌘1-5 / ⌘⇧N / ⌥⌘P）无冲突。
enum ClotheslineHotkeyEntry: String, CaseIterable, Equatable, Sendable {
    case toggle
    case hang

    var keyboardShortcutsName: KeyboardShortcuts.Name {
        switch self {
        case .toggle: return .clotheslineToggle
        case .hang: return .clotheslineHang
        }
    }

    var keyCodeDefaultsKey: String {
        switch self {
        case .toggle: return UserDefaultsKeys.screenshotClotheslineHotkeyToggleKeyCode
        case .hang: return UserDefaultsKeys.screenshotClotheslineHotkeyHangKeyCode
        }
    }

    var modifiersDefaultsKey: String {
        switch self {
        case .toggle: return UserDefaultsKeys.screenshotClotheslineHotkeyToggleModifiers
        case .hang: return UserDefaultsKeys.screenshotClotheslineHotkeyHangModifiers
        }
    }

    /// 默认定义；nil = 默认不绑定（hang）。
    var defaultDefinition: HotkeyDefinition? {
        switch self {
        case .toggle:
            return HotkeyDefinition(keyCode: Int(kVK_ANSI_T),
                                    modifiers: [.control, .option, .command])
        case .hang:
            return nil
        }
    }
}
