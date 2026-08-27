import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

final class ScrollCaptureCoreTests: XCTestCase {

    // MARK: - ScrollStitchMath

    func test_clampOverlap_bounds() {
        XCTAssertEqual(ScrollStitchMath.clampOverlap(-10, height: 100), 0)
        XCTAssertEqual(ScrollStitchMath.clampOverlap(0, height: 100), 0)
        XCTAssertEqual(ScrollStitchMath.clampOverlap(50, height: 100), 50)
        XCTAssertEqual(ScrollStitchMath.clampOverlap(150, height: 100), 100)
        XCTAssertEqual(ScrollStitchMath.clampOverlap(10, height: 0), 0)
    }

    func test_newRows_and_minimumThreshold() {
        XCTAssertEqual(ScrollStitchMath.newRows(height: 200, overlap: 150), 50)
        XCTAssertEqual(ScrollStitchMath.minimumNewRows(height: 200), 8)
        XCTAssertEqual(ScrollStitchMath.minimumNewRows(height: 2000), 10)
        XCTAssertTrue(ScrollStitchMath.hasEnoughNewContent(height: 200, overlap: 150))
        XCTAssertFalse(ScrollStitchMath.hasEnoughNewContent(height: 200, overlap: 195))
    }

    func test_totalHeightPixels_replaysAppendSteps() {
        // 3 frames of 100px with overlaps [80, 70] → 100 + 20 + 30 = 150
        let steps: [ScrollStitchMath.StitchStep] = [
            .append(overlap: 80),
            .append(overlap: 70),
        ]
        XCTAssertEqual(ScrollStitchMath.totalHeightPixels(frameHeight: 100, steps: steps), 150)
    }

    func test_totalHeightPixels_trimBacktracksButFloorsAtFrameHeight() {
        // 100 + 20 + 30 = 150, trim 40 → 110
        let steps: [ScrollStitchMath.StitchStep] = [
            .append(overlap: 80),
            .append(overlap: 70),
            .trimBottom(rows: 40),
        ]
        XCTAssertEqual(ScrollStitchMath.totalHeightPixels(frameHeight: 100, steps: steps), 110)

        // Over-trim never shrinks below a single frame height.
        let overTrim: [ScrollStitchMath.StitchStep] = [
            .append(overlap: 80),
            .trimBottom(rows: 500),
        ]
        XCTAssertEqual(ScrollStitchMath.totalHeightPixels(frameHeight: 100, steps: overTrim), 100)
    }

    func test_clampedTrimRows_limitsToKeepOneFrameHeight() {
        // Stitched 70px of 40px frames → only 30px removable.
        XCTAssertEqual(ScrollStitchMath.clampedTrimRows(60, currentHeightPixels: 70, frameHeight: 40), 30)
        // Nothing beyond a single frame height may be removed.
        XCTAssertEqual(ScrollStitchMath.clampedTrimRows(10, currentHeightPixels: 40, frameHeight: 40), 0)
        // Non-positive inputs never trim.
        XCTAssertEqual(ScrollStitchMath.clampedTrimRows(0, currentHeightPixels: 100, frameHeight: 40), 0)
        XCTAssertEqual(ScrollStitchMath.clampedTrimRows(-5, currentHeightPixels: 100, frameHeight: 40), 0)
    }

    func test_isAtFrameLimit() {
        XCTAssertFalse(ScrollStitchMath.isAtFrameLimit(frameCount: 0))
        XCTAssertFalse(ScrollStitchMath.isAtFrameLimit(frameCount: 99))
        XCTAssertTrue(ScrollStitchMath.isAtFrameLimit(frameCount: 100))
        XCTAssertTrue(ScrollStitchMath.isAtFrameLimit(frameCount: 2, maxFrames: 2))
    }

    // MARK: - ScrollCapturer frame limit with mock capture

    func test_scrollCapturer_returnsAtFrameLimitWhenBudgetExhausted() {
        let solid = Self.makeSolidImage(width: 40, height: 40, color: .red)
        let shifted = Self.makeSolidImage(width: 40, height: 40, color: .blue)

        var callCount = 0
        let capture: ScrollCapturer.RegionCapture = { _, _, _, _, _ in
            callCount += 1
            // First calls feed init + first appends; then keep returning same so
            // nearly-identical may apply — we force frame limit by tiny maxFrames.
            return callCount <= 2 ? solid : shifted
        }

        // maxFrames = 1: init already fills the budget with the first frame.
        let capturer = ScrollCapturer(
            rect: CGRect(x: 0, y: 0, width: 40, height: 40),
            displayID: 0,
            scaleFactor: 1,
            maxFrames: 1,
            capture: capture
        )

        let outcome = capturer.captureSynchronously(expectedShiftPoints: 20)
        XCTAssertEqual(outcome, .atFrameLimit)
    }

    func test_scrollCapturer_noNewContentWhenCaptureReturnsNil() {
        var callCount = 0
        let capture: ScrollCapturer.RegionCapture = { _, _, _, _, _ in
            callCount += 1
            // Init gets one image; subsequent captureSettledFrame always fails.
            if callCount == 1 {
                return Self.makeSolidImage(width: 40, height: 40, color: .green)
            }
            return nil
        }

        let capturer = ScrollCapturer(
            rect: CGRect(x: 0, y: 0, width: 40, height: 40),
            displayID: 0,
            scaleFactor: 1,
            maxFrames: 10,
            capture: capture
        )

        let outcome = capturer.captureSynchronously(expectedShiftPoints: 10)
        XCTAssertEqual(outcome, .noNewContent)
    }

    func test_scrollCapturer_reverseScrollTrimsStitchedResult() {
        // Frame plan: A(red) base → B(blue) +30 → C(green) -30 arms pending →
        // D(yellow) -60 cumulative trims. 40px frames, minimum rows 8.
        final class MockOffsetEstimator: ScrollOffsetEstimating {
            let translations = [30, -30, -60]
            private var call = 0
            func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
                let index = min(call, translations.count - 1)
                defer { call += 1 }
                return ScrollOffsetEstimate(translationY: translations[index], source: .bandConsensus)
            }
        }

        let red = Self.makeSolidImage(width: 40, height: 40, color: .red)
        let blue = Self.makeSolidImage(width: 40, height: 40, color: .blue)
        let green = Self.makeSolidImage(width: 40, height: 40, color: .green)
        let yellow = Self.makeSolidImage(width: 40, height: 40, color: .yellow)

        var call = 0
        let capture: ScrollCapturer.RegionCapture = { _, _, _, _, _ in
            call += 1
            switch call {
            case 1: return red
            case 2, 3: return blue
            case 4, 5: return green
            default: return yellow
            }
        }

        let capturer = ScrollCapturer(
            rect: CGRect(x: 0, y: 0, width: 40, height: 40),
            displayID: 0,
            scaleFactor: 1,
            maxFrames: 10,
            capture: capture,
            offsetEstimator: MockOffsetEstimator()
        )

        // B: forward append → preview grows 40 + 30 = 70.
        XCTAssertEqual(capturer.captureSynchronously(expectedShiftPoints: 0), .appended)
        // C: first reverse signal only arms the pending flag.
        XCTAssertEqual(capturer.captureSynchronously(expectedShiftPoints: 0), .noNewContent)
        // D: cumulative -60 trim clamped to removable 30 → stays at one frame height.
        XCTAssertEqual(capturer.captureSynchronously(expectedShiftPoints: 0), .trimmed)

        let expectation = expectation(description: "stitch-completion")
        var stitched: NSImage?
        capturer.stopAndStitch { image in
            stitched = image
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        // 40 + 30 (append) - 30 (trim) = 40px tall at scale 1.
        XCTAssertNotNil(stitched)
        XCTAssertEqual(stitched?.size.height ?? 0, 40, accuracy: 1.0)
    }

    func test_fakeScreenCaptureClient_forwardsExcludingWindowIDs() async throws {
        let fake = FakeScreenCaptureClient()
        _ = try await fake.captureRegion(
            CGRect(x: 1, y: 2, width: 3, height: 4),
            displayID: 99,
            scaleFactor: 2,
            excludingWindowIDs: [10, 20]
        )
        XCTAssertEqual(fake.captureRegionCalls.count, 1)
        XCTAssertEqual(fake.captureRegionCalls[0].excludingWindowIDs, [10, 20])
        XCTAssertEqual(fake.captureRegionCalls[0].displayID, 99)
    }

    // MARK: - Scroll capture window exclusion list

    func test_scrollCaptureExclusion_includesHostOverlayWindow() {
        let ids = ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: 42,
            hintWindowNumber: 7,
            controlWindowNumber: 8,
            previewWindowNumber: 9
        )
        XCTAssertEqual(ids.first, 42, "host overlay must be first so freeze panel never bakes into frames")
        XCTAssertTrue(ids.contains(42))
        XCTAssertTrue(ids.contains(7))
        XCTAssertTrue(ids.contains(8))
        XCTAssertTrue(ids.contains(9))
    }

    func test_scrollCaptureExclusion_skipsNonPositiveAndDedupes() {
        let ids = ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: 0,
            hintWindowNumber: 5,
            controlWindowNumber: 5,
            previewWindowNumber: -1,
            cropWindowNumber: nil,
            toastWindowNumber: 11
        )
        XCTAssertEqual(ids, [5, 11])
    }

    func test_scrollCaptureExclusion_requiresHostWhenOnlyChromePresent() {
        // Without host, freeze overlay would still cover capture rect.
        let withoutHost = ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: nil,
            hintWindowNumber: 3
        )
        XCTAssertEqual(withoutHost, [3])
        XCTAssertFalse(withoutHost.contains(where: { $0 == 0 }))

        let withHost = ScrollCaptureExclusion.excludedWindowIDs(
            hostWindowNumber: 100,
            hintWindowNumber: 3
        )
        XCTAssertEqual(withHost, [100, 3])
    }

    // MARK: - ScrollCropView geometry

    func test_scrollCropView_croppedImage_respectsHeightFraction() {
        // 100x200 solid image; crop middle 50% → height ~100.
        let image = Self.makeSolidImage(width: 100, height: 200, color: .red)
        let cropView = ScrollCropView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            image: image
        )
        // Force layout so imageFrame is computed.
        cropView.layoutSubtreeIfNeeded()
        cropView.setCropFractionsForTesting(top: 0.25, bottom: 0.75)

        let cropped = cropView.croppedImage()
        XCTAssertEqual(cropped.size.width, 100, accuracy: 1.0)
        // 50% of 200px height.
        XCTAssertEqual(cropped.size.height, 100, accuracy: 2.0)
    }

    func test_scrollCropView_croppedImage_fullRange_keepsOriginalHeight() {
        let image = Self.makeSolidImage(width: 80, height: 160, color: .blue)
        let cropView = ScrollCropView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 500),
            image: image
        )
        cropView.layoutSubtreeIfNeeded()
        cropView.setCropFractionsForTesting(top: 0, bottom: 1)

        let cropped = cropView.croppedImage()
        XCTAssertEqual(cropped.size.width, 80, accuracy: 1.0)
        XCTAssertEqual(cropped.size.height, 160, accuracy: 2.0)
    }

    // MARK: - Helpers

    private static func makeSolidImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}

