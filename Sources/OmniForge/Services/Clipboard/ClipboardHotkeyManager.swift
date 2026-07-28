import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let clipboardHistoryHotkey = Self(
        "clipboardHistoryHotkey",
        default: HotkeyDefinition.defaultClipboard.keyboardShortcut
    )
    static let shelfHotkey = Self(
        "shelfHotkey",
        default: HotkeyDefinition.defaultShelf.keyboardShortcut
    )
}

final class ClipboardHotkeyManager: ObservableObject {
    private let userDefaults: UserDefaults
    private var clipboardHandler: (() -> Void)?
    private var isClipboardListening = false
    private var hasRegisteredClipboardOnKeyUpHandler = false

    @Published var hotkey: HotkeyDefinition {
        didSet {
            guard hotkey != oldValue else { return }
            persistHotkey()
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.hotkey = ClipboardHotkeyManager.loadHotkey(from: userDefaults)
        applyClipboardHotkeyToKeyboardShortcuts()
    }

    deinit {
        stopListening()
    }

    func startListening(handler: @escaping () -> Void) {
        self.clipboardHandler = handler
        isClipboardListening = true
        guard !hasRegisteredClipboardOnKeyUpHandler else { return }

        KeyboardShortcuts.onKeyUp(for: .clipboardHistoryHotkey) { [weak self] in
            guard let self, self.isClipboardListening else { return }
            self.clipboardHandler?()
        }
        hasRegisteredClipboardOnKeyUpHandler = true
    }

    func stopListening() {
        isClipboardListening = false
        clipboardHandler = nil
    }

    func handleRecorderChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let definition = HotkeyDefinition(shortcut: shortcut) else {
            applyClipboardHotkeyToKeyboardShortcuts()
            return
        }
        hotkey = definition
    }

    private func persistHotkey() {
        userDefaults.set(hotkey.keyCode, forKey: UserDefaultsKeys.clipboardHotkeyKeyCode)
        userDefaults.set(hotkey.modifiers.rawValue, forKey: UserDefaultsKeys.clipboardHotkeyModifiers)
        applyClipboardHotkeyToKeyboardShortcuts()
    }

    private func applyClipboardHotkeyToKeyboardShortcuts() {
        KeyboardShortcuts.setShortcut(
            hotkey.keyboardShortcut,
            for: .clipboardHistoryHotkey
        )
    }

    private static func loadHotkey(from userDefaults: UserDefaults) -> HotkeyDefinition {
        guard userDefaults.object(forKey: UserDefaultsKeys.clipboardHotkeyKeyCode) != nil,
              userDefaults.object(forKey: UserDefaultsKeys.clipboardHotkeyModifiers) != nil else {
            return .defaultClipboard
        }

        let keyCode = userDefaults.integer(forKey: UserDefaultsKeys.clipboardHotkeyKeyCode)
        let modifiersRaw = userDefaults.integer(forKey: UserDefaultsKeys.clipboardHotkeyModifiers)
        return HotkeyDefinition(keyCode: keyCode, modifiers: HotkeyModifiers(rawValue: modifiersRaw))
    }

}
