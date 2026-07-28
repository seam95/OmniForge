import Carbon
import XCTest
@testable import OmniForge

final class DefaultsRegistrationTests: XCTestCase {
    func test_register_setsAvailabilityDefaults() {
        let suite = "DefaultsRegistrationTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        for feature in AppFeature.allCases {
            XCTAssertTrue(defaults.bool(forKey: feature.availabilityKey),
                         "Feature \(feature.rawValue) should be available after register")
        }
    }

    func test_register_doesNotOverrideExistingValue() {
        let suite = "DefaultsRegistrationTests_override"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: AppFeature.clipboardHistory.availabilityKey)

        Defaults.register(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: AppFeature.clipboardHistory.availabilityKey),
                       "register must not override existing user values")
    }

    func test_register_setsOnboardingDefaults() {
        let suite = "DefaultsRegistrationTests_onboarding"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertEqual(defaults.bool(forKey: UserDefaultsKeys.hasOnboarded), false,
                       "hasOnboarded should default to false")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.onboardingCompletedVersion), "",
                       "onboardingCompletedVersion should default to empty string")
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.onboardingCurrentStep), 0,
                       "onboardingCurrentStep should default to 0")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.lastWhatsNewVersion), "",
                       "lastWhatsNewVersion should default to empty string")
    }

    func test_register_disablesAllMouseChildFeatures() {
        let suite = "DefaultsRegistrationTests_mouseModule"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.scrollInverterEnabled))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.smoothScrollEnabled))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.mouseNavigationEnabled))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.dockClickMinimize))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.dockClickCycleWindows))
    }

    func test_register_defaultsLastUtilityToolToCleaner() {
        let suite = "DefaultsRegistrationTests_lastUtilityTool"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.lastUtilityTool),
            UtilityTool.cleaner.rawValue
        )
    }

    func test_register_defaultsLastControlCenterPanelToSystemMonitor() {
        let suite = "DefaultsRegistrationTests_lastControlCenterPanel"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.lastControlCenterPanel),
            MenuPanel.systemMonitor.rawValue
        )
    }

    func test_register_setsKeepAwakeDefaults() {
        let suite = "DefaultsRegistrationTests_keepAwake"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes), 0)
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.keepAwakeBatteryLimitPercent), 10)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.keepAwakeAutoStart))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.keepAwakeShowCountdown))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled))
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes), 5)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred))
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.keepAwakeShortcutEnabled))
        XCTAssertEqual(
            defaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyKeyCode),
            HotkeyDefinition.defaultKeepAwake.keyCode
        )
        XCTAssertEqual(
            defaults.integer(forKey: UserDefaultsKeys.keepAwakeHotkeyModifiers),
            HotkeyDefinition.defaultKeepAwake.modifiers.rawValue
        )
        XCTAssertTrue(defaults.bool(forKey: AppFeature.keepAwake.availabilityKey))
    }

    func test_register_setsScreenshotAllInOneHotkeyDefaults() {
        let suite = "DefaultsRegistrationTests_screenshotAllInOne"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertEqual(
            defaults.integer(forKey: UserDefaultsKeys.screenshotHotkeyAllInOneKeyCode),
            HotkeyDefinition.defaultScreenshotAllInOne.keyCode
        )
        XCTAssertEqual(
            defaults.integer(forKey: UserDefaultsKeys.screenshotHotkeyAllInOneModifiers),
            HotkeyDefinition.defaultScreenshotAllInOne.modifiers.rawValue
        )
        XCTAssertEqual(
            HotkeyDefinition.defaultScreenshotAllInOne,
            HotkeyDefinition(keyCode: Int(kVK_ANSI_1), modifiers: [.control, .option, .command])
        )
    }

    /// 注册表不得再包含已退役的快速操作键。
    func test_registrationValues_excludeRetiredScreenshotResultPanelKeys() {
        let registration = Defaults.registrationValues
        let retiredAnchor = "screenshot" + "Quick" + "Access" + "Anchor"
        let retiredAutoClose = "screenshot" + "Quick" + "Access" + "AutoCloseSeconds"
        XCTAssertNil(registration[retiredAnchor])
        XCTAssertNil(registration[retiredAutoClose])
    }

    func test_register_setsNetworkDiagnosticsSegmentDefault() {
        let suite = "DefaultsRegistrationTests_networkDiagnostics"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        Defaults.register(in: defaults)

        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.networkDiagnosticsSegment),
            "network"
        )
        XCTAssertEqual(
            Defaults.registrationValues[UserDefaultsKeys.networkDiagnosticsSegment] as? String,
            "network"
        )
    }
}
