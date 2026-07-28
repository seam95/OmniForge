import XCTest
@testable import OmniForge

@MainActor
final class ShelfServiceTriggersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ShelfServiceTriggersTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        Defaults.register(in: defaults)
        // AppFeature.isAvailable reads UserDefaults.standard.
        UserDefaults.standard.set(true, forKey: AppFeature.shelf.availabilityKey)
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeService() -> ShelfService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfTriggers-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ShelfService(userDefaults: defaults, storeDirectory: dir)
    }

    func test_syncWithPreferences_startsHotkeyAndMonitorWhenEnabled() {
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShortcutEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShakeToOpen)
        defaults.set(false, forKey: UserDefaultsKeys.shelfDropZoneEnabled)

        let service = makeService()
        service.syncWithPreferences()

        XCTAssertTrue(service.isHotkeyListeningForTesting)
        XCTAssertTrue(service.isDragMonitorActiveForTesting)
        XCTAssertEqual(service.syncWithPreferencesCallCount, 1)
    }

    func test_syncWithPreferences_stopsHotkeyAndMonitorWhenDisabled() {
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShortcutEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShakeToOpen)

        let service = makeService()
        service.syncWithPreferences()
        XCTAssertTrue(service.isHotkeyListeningForTesting)
        XCTAssertTrue(service.isDragMonitorActiveForTesting)

        defaults.set(false, forKey: UserDefaultsKeys.shelfEnabled)
        service.syncWithPreferences()

        XCTAssertFalse(service.isHotkeyListeningForTesting)
        XCTAssertFalse(service.isDragMonitorActiveForTesting)
    }

    func test_syncHotkey_offWhenShortcutDisabled() {
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(false, forKey: UserDefaultsKeys.shelfShortcutEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShakeToOpen)
        defaults.set(false, forKey: UserDefaultsKeys.shelfDropZoneEnabled)

        let service = makeService()
        service.syncWithPreferences()

        XCTAssertFalse(service.isHotkeyListeningForTesting)
        XCTAssertTrue(service.isDragMonitorActiveForTesting)
    }

    func test_syncDragMonitor_offWhenShakeAndDropZoneDisabled() {
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShortcutEnabled)
        defaults.set(false, forKey: UserDefaultsKeys.shelfShakeToOpen)
        defaults.set(false, forKey: UserDefaultsKeys.shelfDropZoneEnabled)

        let service = makeService()
        service.syncWithPreferences()

        XCTAssertTrue(service.isHotkeyListeningForTesting)
        XCTAssertFalse(service.isDragMonitorActiveForTesting)
    }
}
