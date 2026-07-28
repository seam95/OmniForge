import XCTest
@testable import OmniForge

final class ShelfDefaultsTests: XCTestCase {
    func test_registeredShelfDefaults() {
        let suiteName = "ShelfDefaultsTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        Defaults.register(in: suite)
        XCTAssertFalse(suite.bool(forKey: UserDefaultsKeys.shelfEnabled))
        XCTAssertTrue(suite.bool(forKey: UserDefaultsKeys.shelfShortcutEnabled))
        XCTAssertTrue(suite.bool(forKey: UserDefaultsKeys.shelfShakeToOpen))
        XCTAssertTrue(suite.bool(forKey: UserDefaultsKeys.shelfDropZoneEnabled))
        XCTAssertFalse(suite.bool(forKey: UserDefaultsKeys.shelfCloseAfterDrop))
        XCTAssertTrue(suite.bool(forKey: UserDefaultsKeys.shelfRemoveAfterDrop))
        XCTAssertEqual(suite.integer(forKey: UserDefaultsKeys.shelfHotkeyKeyCode), HotkeyDefinition.defaultShelf.keyCode)
        XCTAssertEqual(suite.integer(forKey: UserDefaultsKeys.shelfHotkeyModifiers), HotkeyDefinition.defaultShelf.modifiers.rawValue)
    }
}
