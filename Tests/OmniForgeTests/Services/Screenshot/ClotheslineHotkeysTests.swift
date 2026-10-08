import Carbon.HIToolbox
import XCTest
@testable import OmniForge

/// 晾衣绳热键默认值回归：toggle 默认 ⌃⌥⌘T，hang 默认未绑定，且与既有默认键位无冲突。
final class ClotheslineHotkeysTests: XCTestCase {
    func testToggleDefaultIsControlOptionCommandT() throws {
        let def = try XCTUnwrap(ClotheslineHotkeyEntry.toggle.defaultDefinition)
        XCTAssertEqual(def.keyCode, 17)   // kVK_ANSI_T = 0x11（brief 误写 6，以 SDK 常量为准）
        XCTAssertTrue(def.modifiers == HotkeyModifiers([.control, .option, .command]))
    }

    func testHangDefaultIsUnbound() {
        XCTAssertNil(ClotheslineHotkeyEntry.hang.defaultDefinition)
    }

    @MainActor
    func testToggleDefaultNoConflictWithExistingDefaults() {
        var taken: [(Int, HotkeyModifiers)] = [
            (Int(kVK_ANSI_V), [.command, .shift]),               // clipboard ⌘⇧V
            (Int(kVK_ANSI_D), [.control, .option, .command]),    // shelf ⌃⌥⌘D
            (Int(kVK_ANSI_K), [.control, .option, .command]),    // keepAwake ⌃⌥⌘K
            (Int(kVK_ANSI_N), [.command, .shift]),               // stickyNote ⌘⇧N
            (Int(kVK_ANSI_P), [.option, .command]),              // promptOptimizer ⌥⌘P
        ]
        for key in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            taken.append((Int(key), [.control, .option, .command]))   // screenshot ⌃⌥⌘1-5
        }
        let toggle = ClotheslineHotkeyEntry.toggle.defaultDefinition!
        XCTAssertFalse(taken.contains { $0.0 == toggle.keyCode && $0.1 == toggle.modifiers })
    }
}
