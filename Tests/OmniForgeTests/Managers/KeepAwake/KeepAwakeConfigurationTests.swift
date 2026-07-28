import XCTest
@testable import OmniForge

final class KeepAwakeConfigurationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KeepAwakeConfigurationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_load_usesRegisteredDefaultsWhenKeysMissing() throws {
        Defaults.register(in: defaults)
        let snapshot = try KeepAwakeConfiguration(userDefaults: defaults).load()

        XCTAssertEqual(snapshot.defaultDuration, .indefinite)
        XCTAssertEqual(snapshot.batteryLimit, .percent10)
        XCTAssertFalse(snapshot.autoStart)
        XCTAssertFalse(snapshot.showCountdown)
        XCTAssertFalse(snapshot.mouseJiggleEnabled)
        XCTAssertEqual(snapshot.mouseJiggleInterval, .minutes5)
        XCTAssertFalse(snapshot.clamshellPreferred)
        XCTAssertTrue(snapshot.shortcutEnabled)
        XCTAssertEqual(snapshot.hotkey, .defaultKeepAwake)
    }

    func test_load_readsPersistedLegalValues() throws {
        defaults.set(30, forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
        defaults.set(15, forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent)
        defaults.set(true, forKey: UserDefaultsKeys.keepAwakeAutoStart)
        defaults.set(true, forKey: UserDefaultsKeys.keepAwakeShowCountdown)
        defaults.set(true, forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled)
        defaults.set(2, forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
        defaults.set(true, forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
        defaults.set(false, forKey: UserDefaultsKeys.keepAwakeShortcutEnabled)
        defaults.set(HotkeyDefinition.defaultKeepAwake.keyCode, forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode)
        defaults.set(
            HotkeyDefinition.defaultKeepAwake.modifiers.rawValue,
            forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers
        )

        let snapshot = try KeepAwakeConfiguration(userDefaults: defaults).load()
        XCTAssertEqual(snapshot.defaultDuration, .minutes30)
        XCTAssertEqual(snapshot.batteryLimit, .percent15)
        XCTAssertTrue(snapshot.autoStart)
        XCTAssertTrue(snapshot.showCountdown)
        XCTAssertTrue(snapshot.mouseJiggleEnabled)
        XCTAssertEqual(snapshot.mouseJiggleInterval, .minutes2)
        XCTAssertTrue(snapshot.clamshellPreferred)
        XCTAssertFalse(snapshot.shortcutEnabled)
        XCTAssertEqual(snapshot.hotkey, .defaultKeepAwake)
    }

    func test_load_rejectsIllegalPersistedValuesWithoutSubstitution() {
        defaults.set(45, forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
        XCTAssertThrowsError(try KeepAwakeConfiguration(userDefaults: defaults).load()) { error in
            XCTAssertEqual(error as? KeepAwakeError, .invalidDuration(45))
        }

        defaults.removeObject(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
        defaults.set(7, forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent)
        XCTAssertThrowsError(try KeepAwakeConfiguration(userDefaults: defaults).load()) { error in
            XCTAssertEqual(error as? KeepAwakeError, .invalidBatteryLimit(7))
        }

        defaults.removeObject(forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent)
        defaults.set(3, forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
        XCTAssertThrowsError(try KeepAwakeConfiguration(userDefaults: defaults).load()) { error in
            XCTAssertEqual(error as? KeepAwakeError, .invalidPointerInterval(3))
        }
    }
}
