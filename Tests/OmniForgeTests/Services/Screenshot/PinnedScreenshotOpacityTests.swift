import XCTest
@testable import OmniForge

final class PinnedScreenshotOpacityTests: XCTestCase {
    func test_clampedOpacity_bounds() {
        XCTAssertEqual(
            PinnedScreenshotGeometry.clampedOpacity(0),
            PinnedScreenshotGeometry.minOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PinnedScreenshotGeometry.clampedOpacity(1.5),
            PinnedScreenshotGeometry.maxOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PinnedScreenshotGeometry.clampedOpacity(.nan),
            PinnedScreenshotGeometry.defaultOpacity,
            accuracy: 0.0001
        )
        XCTAssertEqual(PinnedScreenshotGeometry.clampedOpacity(0.55), 0.55, accuracy: 0.0001)
    }

    func test_state_setOpacity_clamps() {
        var state = PinnedScreenshotState(opacity: 1)
        state.setOpacity(-1)
        XCTAssertEqual(state.opacity, PinnedScreenshotGeometry.minOpacity, accuracy: 0.0001)
        state.setOpacity(99)
        XCTAssertEqual(state.opacity, PinnedScreenshotGeometry.maxOpacity, accuracy: 0.0001)
    }
}
