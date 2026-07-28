import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class ShelfServicePanelTests: XCTestCase {
    func test_summon_setsVisible_withoutCrash() throws {
        // SPM unit tests do not activate NSApplication; ordering a panel may
        // not mark isVisible. Skip unless we are running under a real app host.
        guard NSApp?.isRunning == true else {
            throw XCTSkip("Requires activated AppKit host; SPM tests skip panel visibility.")
        }

        let suite = "com.omniforge.tests.shelf-panel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfPanelTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: store)
            defaults.removePersistentDomain(forName: suite)
        }

        let service = ShelfService(userDefaults: defaults, storeDirectory: store)
        service.summon()
        XCTAssertTrue(service.isVisible)
        service.hide()
        XCTAssertFalse(service.isVisible)
    }

    func test_togglePin_onlyWhileVisible() {
        let suite = "com.omniforge.tests.shelf-panel-pin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let service = ShelfService(userDefaults: defaults,
                                   storeDirectory: FileManager.default.temporaryDirectory
                                       .appendingPathComponent("ShelfPin-\(UUID().uuidString)"))
        XCTAssertFalse(service.isPinned)
        service.togglePin()
        XCTAssertFalse(service.isPinned, "pin is a no-op when panel is not visible")
    }

    func test_expandDocked_registersActiveForUI() throws {
        guard NSApp?.isRunning == true else {
            throw XCTSkip("Requires activated AppKit host; SPM tests skip panel creation.")
        }

        let suite = "com.omniforge.tests.shelf-docked-active.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Defaults.register(in: defaults)
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfDropZoneEnabled)
        UserDefaults.standard.set(true, forKey: AppFeature.shelf.availabilityKey)

        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfDockedActive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: store)
            defaults.removePersistentDomain(forName: suite)
        }

        let service = ShelfService(userDefaults: defaults, storeDirectory: store)
        XCTAssertNil(ShelfService.activeForUI)

        service.expandDocked()
        // expandDocked schedules syncDockedShelf async; flush main queue.
        let exp = expectation(description: "docked sync")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)

        XCTAssertTrue(service === ShelfService.activeForUI)
    }
}
