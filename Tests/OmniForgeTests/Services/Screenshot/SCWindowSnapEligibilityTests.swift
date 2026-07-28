import CoreGraphics
import XCTest
@testable import OmniForge

final class SCWindowSnapEligibilityTests: XCTestCase {
    func test_normalLayerEligible() {
        XCTAssertTrue(SCWindowSnapEligibility.isEligible(windowLayer: 0))
    }

    func test_dockLayerEligible() {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertTrue(SCWindowSnapEligibility.isEligible(windowLayer: dock))
    }

    func test_menuAndStatusLayersEligible() {
        XCTAssertTrue(SCWindowSnapEligibility.isEligible(
            windowLayer: Int(CGWindowLevelForKey(.mainMenuWindow))
        ))
        XCTAssertTrue(SCWindowSnapEligibility.isEligible(
            windowLayer: Int(CGWindowLevelForKey(.statusWindow))
        ))
    }

    func test_screenSaverLayerNotEligible() {
        let screenSaver = Int(CGWindowLevelForKey(.screenSaverWindow))
        XCTAssertFalse(SCWindowSnapEligibility.isEligible(windowLayer: screenSaver))
    }
}
