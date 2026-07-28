import XCTest
@testable import OmniForge

final class KeepAwakeSettingsStateTests: XCTestCase {
    func test_keepAwakeDiagnosticUsesLocalizedValues() {
        let text = KeepAwakeDiagnosticText.make(
            session: .inactive,
            clamshell: .off,
            recovery: .recovered,
            strings: .zhHans
        )

        XCTAssertFalse(text.contains("inactive"))
        XCTAssertFalse(text.contains("off"))
        XCTAssertFalse(text.contains("recovered"))
        XCTAssertTrue(text.contains("正常睡眠"))
        XCTAssertTrue(text.contains("已恢复"))
    }

    func test_keepAwakeTab_visibleOnlyWhenFeatureAvailable() {
        XCTAssertTrue(
            SettingsToolbarTab.visibleCases(isAvailable: { $0 == .keepAwake }).contains(.keepAwake)
        )
        XCTAssertFalse(
            SettingsToolbarTab.visibleCases(isAvailable: { _ in false }).contains(.keepAwake)
        )
    }

    func test_illegalDuration_isRejectedByParser() {
        XCTAssertThrowsError(try KeepAwakeDuration.parse(7))
        XCTAssertThrowsError(try KeepAwakeDuration.parse(1))
        XCTAssertNoThrow(try KeepAwakeDuration.parse(15))
        XCTAssertNoThrow(try KeepAwakeDuration.parse(0))
    }

    func test_illegalBattery_isRejectedByParser() {
        XCTAssertThrowsError(try KeepAwakeBatteryLimit.parse(7))
        XCTAssertNoThrow(try KeepAwakeBatteryLimit.parse(10))
    }

    func test_settingsNavigation_selectsKeepAwakeWhenAvailable() {
        let navigation = SettingsNavigationModel(selectedTab: .general)
        navigation.select(.keepAwake, isAvailable: { $0 == .keepAwake || $0 == .launchAtLogin })
        XCTAssertEqual(navigation.selectedTab, .keepAwake)
    }

    func test_settingsNavigation_fallsBackWhenTargetUnavailable() {
        let navigation = SettingsNavigationModel(selectedTab: .general)
        navigation.select(.keepAwake, isAvailable: { _ in false })
        // keepAwake 不可见时回退到第一个可见 tab（general 始终可见）
        XCTAssertEqual(navigation.selectedTab, .general)
    }
}
