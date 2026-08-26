import XCTest
@testable import OmniForge

final class ProviderSwitchSettingsViewTests: XCTestCase {
    func test_settingsPresentation_keepsInlineAddProviderButton() {
        XCTAssertTrue(ProviderSwitchPresentation.settings.showsInlineAddProviderButton)
        XCTAssertFalse(ProviderSwitchPresentation.settings.showsFooterAddProviderLink)
        XCTAssertEqual(
            ProviderSwitchPresentation.settings.addProviderRoute,
            .profileEditor
        )
    }

    func test_menuBarPresentation_routesAddProviderToSettings() {
        XCTAssertFalse(ProviderSwitchPresentation.menuBar.showsInlineAddProviderButton)
        XCTAssertTrue(ProviderSwitchPresentation.menuBar.showsFooterAddProviderLink)
        XCTAssertEqual(
            ProviderSwitchPresentation.menuBar.addProviderRoute,
            .providerSettings
        )
    }

    func test_settingsPresentation_keepsProfileManagementActions() {
        XCTAssertTrue(ProviderSwitchPresentation.settings.showsProfileManagementMenu)
        XCTAssertFalse(ProviderSwitchPresentation.settings.showsLaunchCommandCopyButton)
    }

    func test_menuBarPresentation_exposesOnlyLaunchCommandCopyAction() {
        XCTAssertFalse(ProviderSwitchPresentation.menuBar.showsProfileManagementMenu)
        XCTAssertTrue(ProviderSwitchPresentation.menuBar.showsLaunchCommandCopyButton)
    }

    func test_launchCommandCopyLocalization_isAvailable() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.providerCopyLaunchCommand.isEmpty)
            XCTAssertFalse(strings.providerLaunchCommandCopied.isEmpty)
            XCTAssertFalse(strings.providerLaunchCommandCopyFailed.isEmpty)
        }
    }
}
