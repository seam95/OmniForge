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
}
