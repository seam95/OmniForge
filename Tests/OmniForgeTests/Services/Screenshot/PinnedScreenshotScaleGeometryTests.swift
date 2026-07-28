import CoreGraphics
import XCTest
@testable import OmniForge

final class PinnedScreenshotScaleGeometryTests: XCTestCase {
    func test_displaySize_preservesAspectRatio() {
        let size = PinnedScreenshotGeometry.displaySize(
            pixelWidth: 200,
            pixelHeight: 100,
            pointPixelScale: 2,
            scale: 1.5
        )
        XCTAssertNotNil(size)
        // natural 100×50 points * 1.5
        XCTAssertEqual(size!.width, 150, accuracy: 0.001)
        XCTAssertEqual(size!.height, 75, accuracy: 0.001)
        XCTAssertEqual(size!.width / size!.height, 2, accuracy: 0.001)
    }

    func test_clampedDisplaySize_enforcesMinMaxEdges() {
        let tiny = PinnedScreenshotGeometry.clampedDisplaySize(CGSize(width: 10, height: 5))
        XCTAssertNotNil(tiny)
        XCTAssertGreaterThanOrEqual(min(tiny!.width, tiny!.height), PinnedScreenshotGeometry.minDisplayEdgePoints - 0.01)
        XCTAssertEqual(tiny!.width / tiny!.height, 2, accuracy: 0.01)

        let huge = PinnedScreenshotGeometry.clampedDisplaySize(CGSize(width: 10_000, height: 5_000))
        XCTAssertNotNil(huge)
        XCTAssertLessThanOrEqual(max(huge!.width, huge!.height), PinnedScreenshotGeometry.maxDisplayEdgePoints + 0.01)
        XCTAssertEqual(huge!.width / huge!.height, 2, accuracy: 0.01)
    }

    func test_invalidInputs_returnNil() {
        XCTAssertNil(PinnedScreenshotGeometry.naturalDisplaySize(pixelWidth: 0, pixelHeight: 10, pointPixelScale: 2))
        XCTAssertNil(PinnedScreenshotGeometry.naturalDisplaySize(pixelWidth: 10, pixelHeight: 10, pointPixelScale: 0))
        XCTAssertNil(PinnedScreenshotGeometry.clampedDisplaySize(CGSize(width: -1, height: 10)))
        XCTAssertNil(PinnedScreenshotGeometry.clampedDisplaySize(.zero))
    }

    func test_scaledFrame_windowCenter_keepsCenter() {
        let frame = CGRect(x: 100, y: 200, width: 200, height: 100)
        let scaled = PinnedScreenshotGeometry.scaledFrame(
            currentFrame: frame,
            scaleFactor: 2,
            anchor: .windowCenter
        )
        XCTAssertNotNil(scaled)
        XCTAssertEqual(scaled!.midX, frame.midX, accuracy: 0.01)
        XCTAssertEqual(scaled!.midY, frame.midY, accuracy: 0.01)
        XCTAssertEqual(scaled!.width / scaled!.height, 2, accuracy: 0.01)
    }

    func test_clampedScale_bounds() {
        XCTAssertEqual(PinnedScreenshotGeometry.clampedScale(0.001), PinnedScreenshotGeometry.minScale)
        XCTAssertEqual(PinnedScreenshotGeometry.clampedScale(100), PinnedScreenshotGeometry.maxScale)
        XCTAssertEqual(PinnedScreenshotGeometry.clampedScale(.nan), PinnedScreenshotGeometry.defaultScale)
    }

    func test_frameFittingVisibleArea_staysInside() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = PinnedScreenshotGeometry.frameFittingVisibleArea(
            size: CGSize(width: 200, height: 100),
            preferredOrigin: CGPoint(x: 900, y: 700),
            visibleFrame: visible
        )
        XCTAssertNotNil(frame)
        XCTAssertTrue(visible.contains(frame!))
    }

    // MARK: - fittedSize（参照 capcap PinLauncher.fittedSize：只缩小不放大）

    func test_fittedSize_smallImageNotUpscaled() {
        // 小图：绝不被放大（钉住"自动放大"的回归）
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let small = PinnedScreenshotGeometry.fittedSize(for: CGSize(width: 50, height: 30), in: visible)
        XCTAssertEqual(small.width, 50, accuracy: 0.001)
        XCTAssertEqual(small.height, 30, accuracy: 0.001)
    }

    func test_fittedSize_largeImageShrunkToScreenKeepingAspect() {
        // 大图超出可见区：按宽高比缩小到屏内
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = PinnedScreenshotGeometry.fittedSize(for: CGSize(width: 2880, height: 1800), in: visible)
        // maxW = 1440-80=1360, maxH=900-80=820；ratio=min(1, 1360/2880, 820/1800)=820/1800
        let expectedRatio = min(1.0, min(1360.0 / 2880.0, 820.0 / 1800.0))
        XCTAssertEqual(fitted.width, floor(2880 * expectedRatio), accuracy: 0.001)
        XCTAssertEqual(fitted.height, floor(1800 * expectedRatio), accuracy: 0.001)
        XCTAssertEqual(fitted.width / fitted.height, 2880.0 / 1800.0, accuracy: 0.01)
    }

    func test_fittedSize_exactlyFittingReturnedUnchanged() {
        // 刚好等于可见边界的图：原样返回（ratio==1）
        let visible = CGRect(x: 0, y: 0, width: 1080, height: 800)
        let edge = PinnedScreenshotGeometry.fittedSize(for: CGSize(width: 1000, height: 720), in: visible)
        XCTAssertEqual(edge.width, 1000, accuracy: 0.001)
        XCTAssertEqual(edge.height, 720, accuracy: 0.001)
    }

    func test_fittedSize_invalidInputReturnsOriginal() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(PinnedScreenshotGeometry.fittedSize(for: .zero, in: visible), .zero)
        let neg = PinnedScreenshotGeometry.fittedSize(for: CGSize(width: -10, height: 10), in: visible)
        XCTAssertEqual(neg.width, -10)
        XCTAssertEqual(neg.height, 10)
    }
}
