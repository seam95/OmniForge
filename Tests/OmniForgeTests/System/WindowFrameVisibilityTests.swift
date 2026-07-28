import AppKit
import XCTest
@testable import OmniForge

final class WindowFrameVisibilityTests: XCTestCase {
    func test_normalizedFrame_keepsFrameWhenIntersectingVisibleScreen() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900)
        ]
        let frame = NSRect(x: 120, y: 180, width: 720, height: 460)

        let normalized = WindowFrameVisibility.normalizedFrame(
            frame,
            visibleScreens: screens,
            minimumVisibleSize: NSSize(width: 50, height: 50),
            centerFallback: { NSRect(x: 360, y: 220, width: 720, height: 460) }
        )

        XCTAssertEqual(normalized, frame)
    }

    func test_normalizedFrame_recentersWhenCompletelyOffscreen() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900)
        ]
        let offscreen = NSRect(x: 0, y: -2754, width: 720, height: 460)
        let fallback = NSRect(x: 360, y: 220, width: 720, height: 460)

        let normalized = WindowFrameVisibility.normalizedFrame(
            offscreen,
            visibleScreens: screens,
            minimumVisibleSize: NSSize(width: 50, height: 50),
            centerFallback: { fallback }
        )

        XCTAssertEqual(normalized, fallback)
    }

    func test_normalizedFrame_recentersWhenOnlyTinySliverIntersects() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900)
        ]
        // 仅 20x20 落在屏内，低于 50x50 阈值
        let barelyVisible = NSRect(x: -700, y: -440, width: 720, height: 460)
        let fallback = NSRect(x: 100, y: 100, width: 720, height: 460)

        let normalized = WindowFrameVisibility.normalizedFrame(
            barelyVisible,
            visibleScreens: screens,
            minimumVisibleSize: NSSize(width: 50, height: 50),
            centerFallback: { fallback }
        )

        XCTAssertEqual(normalized, fallback)
    }

    func test_normalizedFrame_acceptsMultiScreenIntersection() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: -200, width: 2560, height: 1440)
        ]
        let frameOnSecondary = NSRect(x: 1800, y: 100, width: 720, height: 460)

        let normalized = WindowFrameVisibility.normalizedFrame(
            frameOnSecondary,
            visibleScreens: screens,
            minimumVisibleSize: NSSize(width: 50, height: 50),
            centerFallback: { NSRect(x: 0, y: 0, width: 720, height: 460) }
        )

        XCTAssertEqual(normalized, frameOnSecondary)
    }
}
