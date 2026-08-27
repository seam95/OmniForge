import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

final class ScrollOffsetEstimatorTests: XCTestCase {
    private static let imageSize = CGSize(width: 100, height: 300)

    private static func makeImage() -> CGImage? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(imageSize.width),
            pixelsHigh: Int(imageSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        return rep?.cgImage
    }

    private func makeEstimator(
        bandValues: [CGFloat],
        fullFrame: ScrollAlignmentCandidate?
    ) -> VisionBandOffsetEstimator {
        var bandCall = 0
        return VisionBandOffsetEstimator { current, _ in
            // Bands crop to height 100 (max(80, 300/3)); the full frame is 300.
            if current.height == 100 {
                let index = min(bandCall, bandValues.count - 1)
                defer { bandCall += 1 }
                return ScrollAlignmentCandidate(x: 0, y: bandValues[index], confidence: 0.9)
            }
            return fullFrame
        }
    }

    private func estimate(
        bandValues: [CGFloat],
        fullFrame: ScrollAlignmentCandidate?
    ) -> ScrollOffsetEstimate? {
        guard let current = Self.makeImage(), let previous = Self.makeImage() else {
            XCTFail("failed to build test images")
            return nil
        }
        return makeEstimator(bandValues: bandValues, fullFrame: fullFrame)
            .estimate(current: current, previous: previous)
    }

    func test_bandConsensus_whenMajorityAgrees() {
        let estimate = estimate(
            bandValues: [40, 40, 40, 41, 39],
            // Full-frame interference must never be consulted.
            fullFrame: ScrollAlignmentCandidate(x: 0, y: 999, confidence: 0.99)
        )
        XCTAssertEqual(estimate?.translationY, 40)
        XCTAssertEqual(estimate?.source, .bandConsensus)
    }

    func test_validatedBandFallback_whenPartialConsensusMatchesFullFrame() {
        // Three bands agree on 40; two outliers at 200 break the majority.
        let estimate = estimate(
            bandValues: [40, 40, 40, 200, 200],
            fullFrame: ScrollAlignmentCandidate(x: 0, y: 42, confidence: 0.85)
        )
        XCTAssertEqual(estimate?.translationY, 40)
        XCTAssertEqual(estimate?.source, .validatedBandFallback)
    }

    func test_validatedBandFallback_rejectsFullFrameDisagreement() {
        let estimate = estimate(
            bandValues: [40, 40, 40, 200, 200],
            // Full frame points elsewhere (|50 - 40| > 3) and lacks the 0.9
            // confidence for the last-resort path.
            fullFrame: ScrollAlignmentCandidate(x: 0, y: 90, confidence: 0.85)
        )
        XCTAssertNil(estimate)
    }

    func test_fullFrameFallback_whenBandsScatterButFrameIsConfident() {
        let estimate = estimate(
            bandValues: [10, 60, 110, 160, 210],
            fullFrame: ScrollAlignmentCandidate(x: 0, y: 50, confidence: 0.95)
        )
        XCTAssertEqual(estimate?.translationY, 50)
        XCTAssertEqual(estimate?.source, .fullFrameFallback)
    }

    func test_nil_whenNothingAgreesAndFrameUnconfident() {
        XCTAssertNil(estimate(
            bandValues: [10, 60, 110, 160, 210],
            fullFrame: ScrollAlignmentCandidate(x: 0, y: 50, confidence: 0.5)
        ))
        XCTAssertNil(estimate(
            bandValues: [10, 60, 110, 160, 210],
            fullFrame: nil
        ))
    }

    func test_bandValidityFiltersExtremeOffsets() {
        // 0.85 * 300 = 255: every band offset is out of range and dropped,
        // leaving only the confident full-frame match.
        let estimate = estimate(
            bandValues: [260, 260, 260, 260, 260],
            fullFrame: ScrollAlignmentCandidate(x: 0, y: 40, confidence: 0.95)
        )
        XCTAssertEqual(estimate?.translationY, 40)
        XCTAssertEqual(estimate?.source, .fullFrameFallback)
    }

    func test_bandValidityRejectsHorizontalMovement() {
        // Bands agree vertically but drift horizontally → dropped.
        var bandCall = 0
        let estimator = VisionBandOffsetEstimator { current, _ in
            if current.height == 100 {
                bandCall += 1
                return ScrollAlignmentCandidate(x: 10, y: 40, confidence: 0.9)
            }
            return ScrollAlignmentCandidate(x: 0, y: 40, confidence: 0.95)
        }
        guard let image = Self.makeImage() else {
            XCTFail("failed to build test image")
            return
        }
        let estimate = estimator.estimate(current: image, previous: image)
        XCTAssertEqual(estimate?.translationY, 40)
        XCTAssertEqual(estimate?.source, .fullFrameFallback)
    }

    func test_reverseTranslation_reportsNegativePixelOffset() {
        let estimate = estimate(
            bandValues: [-40, -40, -40, -40, -40],
            fullFrame: nil
        )
        XCTAssertEqual(estimate?.translationY, -40)
        XCTAssertEqual(estimate?.source, .bandConsensus)
    }

    func test_mismatchedDimensions_returnNil() {
        let wide = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 300,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )?.cgImage
        let tall = Self.makeImage()
        guard let wide, let tall else {
            XCTFail("failed to build test images")
            return
        }
        let estimator = VisionBandOffsetEstimator { _, _ in
            ScrollAlignmentCandidate(x: 0, y: 40, confidence: 0.99)
        }
        XCTAssertNil(estimator.estimate(current: wide, previous: tall))
    }
}
