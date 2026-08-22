import XCTest
@testable import OmniForge

final class SettingsToolbarTabScreenshotTests: XCTestCase {
    func test_screenshotTab_visibleWhenFeatureAvailable() {
        XCTAssertTrue(
            SettingsToolbarTab.visibleCases(isAvailable: { $0 == .screenshot }).contains(.screenshot)
        )
        XCTAssertFalse(
            SettingsToolbarTab.visibleCases(isAvailable: { _ in false }).contains(.screenshot)
        )
    }

    func test_screenshotTab_systemImageAndTitle() {
        XCTAssertEqual(SettingsToolbarTab.screenshot.systemImage, "camera.viewfinder")
        XCTAssertEqual(SettingsToolbarTab.screenshot.title(in: .en), "Screenshot")
        XCTAssertEqual(SettingsToolbarTab.screenshot.title(in: .zhHans), "截图")
    }

    func test_allCases_includesScreenshotInStableOrder() {
        XCTAssertEqual(SettingsToolbarTab.allCases.count, 12)
        XCTAssertEqual(
            SettingsToolbarTab.allCases,
            [
                .general, .features, .inputMethod, .clipboard, .shelf, .screenshot, .mouse,
                .performance, .tokenUsage, .keepAwake, .cleaner, .uninstaller
            ]
        )
    }
}
