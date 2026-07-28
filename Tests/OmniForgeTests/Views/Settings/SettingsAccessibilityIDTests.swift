import XCTest
@testable import OmniForge

final class SettingsAccessibilityIDTests: XCTestCase {
    func test_allSettingsAccessibilityIdentifiersAreUnique() {
        let identifiers = SettingsAccessibilityID.allCases.map(\.rawValue)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func test_generalSettingsIdentifiersAreUniqueAndStable() {
        let identifiers = [
            SettingsAccessibilityID.generalLanguage.rawValue,
            SettingsAccessibilityID.generalLaunchAtLogin.rawValue,
            SettingsAccessibilityID.generalHideDockIcon.rawValue,
            SettingsAccessibilityID.generalLaunchAtLoginError.rawValue,
        ]

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(SettingsAccessibilityID.generalLanguage.rawValue, "settings.general.language")
        XCTAssertEqual(SettingsAccessibilityID.generalLaunchAtLogin.rawValue, "settings.general.launchAtLogin")
        XCTAssertEqual(SettingsAccessibilityID.generalHideDockIcon.rawValue, "settings.general.hideDockIcon")
    }

    func test_cleanerCancelScanIdentifierIsStable() {
        XCTAssertEqual(
            SettingsAccessibilityID.cleanerCancelScan.rawValue,
            "cleaner.scan.cancel"
        )
    }
}
