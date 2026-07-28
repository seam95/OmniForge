import Carbon
import XCTest
@testable import OmniForge

final class ClipboardHotkeyManagerTests: XCTestCase {
    func test_defaultHotkeyIsCommandShiftV() {
        let defaults = UserDefaults(suiteName: "ClipboardHotkeyManagerTests_default")!
        defaults.removePersistentDomain(forName: "ClipboardHotkeyManagerTests_default")

        let manager = ClipboardHotkeyManager(userDefaults: defaults)

        XCTAssertEqual(manager.hotkey, .defaultClipboard)
    }

    func test_persistsHotkeyToUserDefaults() {
        let defaults = UserDefaults(suiteName: "ClipboardHotkeyManagerTests_persist")!
        defaults.removePersistentDomain(forName: "ClipboardHotkeyManagerTests_persist")

        let manager = ClipboardHotkeyManager(userDefaults: defaults)
        manager.hotkey = HotkeyDefinition(keyCode: Int(kVK_ANSI_C), modifiers: [.command])

        let reloaded = ClipboardHotkeyManager(userDefaults: defaults)
        XCTAssertEqual(reloaded.hotkey, HotkeyDefinition(keyCode: Int(kVK_ANSI_C), modifiers: [.command]))
    }
}
