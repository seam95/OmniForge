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

    // MARK: - clampedFrame（面板必须完整可见口径）

    func test_clampedFrame_pullsPartiallyHangingFrameBackInside() {
        // 故障现场复刻：窗口底部 200pt 悬在副屏底边外（旧 50×50 口径会放行）
        let screens = [
            NSRect(x: 0, y: 0, width: 2560, height: 1410),
            NSRect(x: 528, y: -715, width: 1280, height: 685)
        ]
        let hanging = NSRect(x: 599, y: -1000, width: 720, height: 460)

        let clamped = WindowFrameVisibility.clampedFrame(
            hanging,
            visibleScreens: screens,
            centerFallback: {
                XCTFail("与屏幕相交时不应走居中回落")
                return .zero
            }
        )

        XCTAssertEqual(clamped.size, hanging.size)
        // 与副屏相交面积最大 → 完整夹进副屏可见区
        XCTAssertTrue(screens[1].contains(clamped), "应完整落入副屏可见区，得到 \(clamped)")
    }

    func test_clampedFrame_keepsFullyVisibleFrame() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let frame = NSRect(x: 120, y: 180, width: 720, height: 460)

        let clamped = WindowFrameVisibility.clampedFrame(
            frame,
            visibleScreens: screens,
            centerFallback: {
                XCTFail("完整可见时不应走居中回落")
                return .zero
            }
        )

        XCTAssertEqual(clamped, frame)
    }

    func test_clampedFrame_recentersWhenCompletelyOffscreen() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let offscreen = NSRect(x: 0, y: -2754, width: 720, height: 460)
        let fallback = NSRect(x: 360, y: 220, width: 720, height: 460)

        let clamped = WindowFrameVisibility.clampedFrame(
            offscreen,
            visibleScreens: screens,
            centerFallback: { fallback }
        )

        XCTAssertEqual(clamped, fallback)
    }

    func test_clampedFrame_prefersScreenWithLargestIntersection() {
        // 窗口横跨两屏：主屏相交 720×100，右屏相交 720×360 → 夹进右屏
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: 0, width: 2560, height: 1440)
        ]
        let straddling = NSRect(x: 1800, y: -100, width: 720, height: 460)

        let clamped = WindowFrameVisibility.clampedFrame(
            straddling,
            visibleScreens: screens,
            centerFallback: {
                XCTFail("与屏幕相交时不应走居中回落")
                return .zero
            }
        )

        XCTAssertEqual(clamped.origin.y, 0, "应夹回右屏底边内侧，得到 \(clamped)")
        XCTAssertTrue(screens[1].contains(clamped))
    }

    func test_clampedFrame_alignsToMinWhenLargerThanVisibleArea() {
        let visible = NSRect(x: 100, y: 100, width: 500, height: 300)
        let oversized = NSRect(x: 9999, y: 9999, width: 720, height: 460)

        let clamped = WindowFrameVisibility.clampedFrame(oversized, toVisibleFrame: visible)

        XCTAssertEqual(clamped.origin, visible.origin)
        XCTAssertEqual(clamped.size, oversized.size)
    }
}
