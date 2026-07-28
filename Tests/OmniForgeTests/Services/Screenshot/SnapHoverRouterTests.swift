import AppKit
import XCTest
@testable import OmniForge

final class SnapHoverRouterTests: XCTestCase {
    func test_route_picksScreenContainingMouse() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 1280, height: 800)
        let screens = [
            SnapHoverScreen(id: "p", frame: primary),
            SnapHoverScreen(id: "s", frame: secondary),
        ]
        let hit = SnapHoverRouter.target(
            mouseAppKitGlobal: CGPoint(x: 1500, y: 100),
            screens: screens
        )
        XCTAssertEqual(hit?.id, "s")
        XCTAssertEqual(hit!.localPoint.x, 60, accuracy: 0.001)
        XCTAssertEqual(hit!.localPoint.y, 100, accuracy: 0.001)
    }

    func test_route_primaryWhenOnPrimary() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 1280, height: 800)
        let screens = [
            SnapHoverScreen(id: "p", frame: primary),
            SnapHoverScreen(id: "s", frame: secondary),
        ]
        let hit = SnapHoverRouter.target(
            mouseAppKitGlobal: CGPoint(x: 10, y: 20),
            screens: screens
        )
        XCTAssertEqual(hit?.id, "p")
        XCTAssertEqual(hit?.localPoint.x, 10)
        XCTAssertEqual(hit?.localPoint.y, 20)
    }

    func test_route_nilWhenOutsideAllScreens() {
        let screens = [SnapHoverScreen(id: "p", frame: NSRect(x: 0, y: 0, width: 100, height: 100))]
        let hit = SnapHoverRouter.target(
            mouseAppKitGlobal: CGPoint(x: -50, y: -50),
            screens: screens
        )
        XCTAssertNil(hit)
    }
}
