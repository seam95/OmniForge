import CoreGraphics
import XCTest
@testable import OmniForge

final class PointerActivityPosterTests: XCTestCase {
    func test_nudgeGeometry_fourEdgesAndNegativeOrigin() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(
            PointerActivityGeometry.nudgeTarget(from: CGPoint(x: 10, y: 10), bounds: bounds),
            CGPoint(x: 11, y: 10)
        )
        // 右边界：向左
        XCTAssertEqual(
            PointerActivityGeometry.nudgeTarget(from: CGPoint(x: 99, y: 10), bounds: bounds),
            CGPoint(x: 98, y: 10)
        )

        let neg = CGRect(x: -200, y: -100, width: 100, height: 80)
        XCTAssertEqual(
            PointerActivityGeometry.nudgeTarget(from: CGPoint(x: -150, y: -50), bounds: neg),
            CGPoint(x: -149, y: -50)
        )
        // 触右边界
        XCTAssertEqual(
            PointerActivityGeometry.nudgeTarget(from: CGPoint(x: -101, y: -50), bounds: neg),
            CGPoint(x: -102, y: -50)
        )
    }

    func test_displayBounds_selectsContainingDisplayAmongMultiple() {
        var posted: [CGPoint] = []
        let api = PointerActivityAPI(
            currentLocation: { CGPoint(x: 120, y: 20) },
            activeDisplayCount: { 2 },
            activeDisplayList: { _ in [1, 2] },
            displayBounds: { id in
                id == 1
                    ? CGRect(x: 0, y: 0, width: 100, height: 100)
                    : CGRect(x: 100, y: 0, width: 100, height: 100)
            },
            postEvent: { _ in },
            makeMouseEvent: { location in
                posted.append(location)
                return CGEvent(
                    mouseEventSource: nil,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: location,
                    mouseButton: .left
                )
            }
        )
        let poster = PointerActivityPoster(api: api)
        let bounds = poster.displayBounds(containing: CGPoint(x: 120, y: 20))
        XCTAssertEqual(bounds, CGRect(x: 100, y: 0, width: 100, height: 100))
        try? poster.postMouseMoved(to: CGPoint(x: 121, y: 20))
        XCTAssertEqual(posted.last, CGPoint(x: 121, y: 20))
    }
}
