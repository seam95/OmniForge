import XCTest
@testable import OmniForge

final class AppFeatureScreenshotCatalogTests: XCTestCase {
    func test_screenshot_catalogContract() {
        XCTAssertEqual(AppFeature.screenshot.rawValue, "screenshot")
        XCTAssertEqual(AppFeature.screenshot.group, .capture)
        XCTAssertEqual(AppFeature.screenshot.enabledKeys, [UserDefaultsKeys.screenshotEnabled])
        XCTAssertEqual(AppFeature.screenshot.possiblePermissions, [.screenRecording])
        XCTAssertEqual(AppFeature.screenshot.permissions, [.screenRecording])
        XCTAssertEqual(AppFeature.screenshot.symbolName, "camera.viewfinder")
        XCTAssertFalse(AppFeature.screenshot.hubName(in: .en).isEmpty)
        XCTAssertFalse(AppFeature.screenshot.hubName(in: .zhHans).isEmpty)
        XCTAssertFalse(AppFeature.screenshot.hubDescription(in: .en).isEmpty)
        XCTAssertFalse(AppFeature.screenshot.hubDescription(in: .zhHans).isEmpty)
        XCTAssertFalse(FeatureGroup.capture.hubTitle(in: .en).isEmpty)
        XCTAssertFalse(FeatureGroup.capture.hubTitle(in: .zhHans).isEmpty)
    }

    func test_screenshot_permissionUsage_isRequiredForScreenRecording() {
        XCTAssertEqual(
            AppFeature.screenshot.permissionUsage(for: .screenRecording),
            .required
        )
        XCTAssertNil(AppFeature.screenshot.permissionUsage(for: .accessibility))
        XCTAssertNil(AppFeature.screenshot.permissionUsage(for: .fullDiskAccess))
    }

    func test_screenRecording_permissionHubCopy() {
        XCTAssertEqual(AppPermission.screenRecording.symbolName, "rectangle.dashed.badge.record")
        XCTAssertFalse(AppPermission.screenRecording.hubName(in: .en).isEmpty)
        XCTAssertFalse(AppPermission.screenRecording.hubName(in: .zhHans).isEmpty)
        XCTAssertFalse(AppPermission.screenRecording.hubDescription(in: .en).isEmpty)
        XCTAssertFalse(AppPermission.screenRecording.hubDescription(in: .zhHans).isEmpty)
    }

    func test_captureGroup_containsScreenshotOnly() {
        XCTAssertEqual(FeatureGroup.features(in: .capture), [.screenshot])
    }
}
