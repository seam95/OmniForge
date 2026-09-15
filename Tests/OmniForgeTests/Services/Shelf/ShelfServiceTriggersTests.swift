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

    // MARK: - 卸载终态（审查 R10）

    /// teardown 后：快捷键/拖拽监控封闭、窗口与 hosting 解除、再次 teardown 幂等。
    func test_teardown_releasesResourcesAndIsIdempotent() {
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShortcutEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfShakeToOpen)

        let service = makeService()
        service.syncWithPreferences()
        XCTAssertTrue(service.isHotkeyListeningForTesting)
        XCTAssertTrue(service.isDragMonitorActiveForTesting)

        service.teardown()

        XCTAssertFalse(service.isHotkeyListeningForTesting, "快捷键回调封闭")
        XCTAssertFalse(service.isDragMonitorActiveForTesting, "拖拽监控移除")
        XCTAssertNil(ShelfService.activeForUI, "UI 活跃引用清空")
        // 快捷键真值仍在 UserDefaults（重装后 recorder 显示原绑定）。
        XCTAssertNotNil(defaults.object(forKey: UserDefaultsKeys.shelfHotkeyKeyCode))

        // 幂等：重复 teardown 无副作用。
        service.teardown()
        XCTAssertFalse(service.isDragMonitorActiveForTesting)
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
