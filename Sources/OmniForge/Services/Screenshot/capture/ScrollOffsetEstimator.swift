import CoreGraphics
import Foundation
import Vision

/// How a frame-to-frame vertical offset was resolved.
enum ScrollOffsetSource: Equatable {
    /// A majority of comparison bands agreed on the translation.
    case bandConsensus
    /// A partial band consensus validated against a full-frame match.
    case validatedBandFallback
    /// A high-confidence full-frame match alone.
    case fullFrameFallback

    var diagnosticName: String {
        switch self {
        case .bandConsensus: return "band-consensus"
        case .validatedBandFallback: return "validated-band-fallback"
        case .fullFrameFallback: return "full-frame-fallback"
        }
    }
}

/// Vertical translation between two consecutive scroll frames, in pixels.
/// Positive Y means fresh content was revealed at the bottom (downward scroll).
struct ScrollOffsetEstimate: Equatable {
    let translationY: Int
    let source: ScrollOffsetSource
}

/// Raw registration result for one band (or the full frame).
struct ScrollAlignmentCandidate: Equatable {
    let x: CGFloat
    let y: CGFloat
    let confidence: Float
}

protocol ScrollOffsetEstimating: AnyObject {
    /// Returns the pixel-space vertical translation from `previous` to `current`,
    /// or nil when no reliable alignment could be established.
    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate?
}

/// 5-band consensus registration.
///
/// Both frames are cropped into horizontal bands that are registered
/// independently; a translation is only trusted when several bands agree.
/// Local motion (video, animated images, blinking cursors) corrupts isolated
/// bands, which the consensus vote filters out, while a single full-frame
/// registration would be dragged along by such motion.
final class VisionBandOffsetEstimator: ScrollOffsetEstimating {
    typealias AlignmentFinder = (_ current: CGImage, _ previous: CGImage) -> ScrollAlignmentCandidate?

    private let bandCount = 5
    private let minimumBandHeight = 80
    /// Bands count as agreeing when their Y translations differ by at most this many pixels.
    private let agreementTolerance: CGFloat = 3
    private let maximumHorizontalMovement: CGFloat = 3
    private let minimumOverlapFraction: CGFloat = 0.15
    private let consensusBandCount = 4
    private let partialConsensusBandCount = 3
    private let validatedBandConfidence: Float = 0.8
    private let fullFrameConfidence: Float = 0.9
    private let findAlignment: AlignmentFinder

    init(findAlignment: @escaping AlignmentFinder = VisionBandOffsetEstimator.findAlignmentViaVision) {
        self.findAlignment = findAlignment
    }

    func estimate(current: CGImage, previous: CGImage) -> ScrollOffsetEstimate? {
        guard current.width == previous.width,
              current.height == previous.height else {
            return nil
        }

        let frameHeight = CGFloat(current.height)
        let bandCandidates = comparisonBands(for: current).compactMap { band -> ScrollAlignmentCandidate? in
            guard let currentBand = current.cropping(to: band),
                  let previousBand = previous.cropping(to: band) else {
                return nil
            }
            guard let candidate = findAlignment(currentBand, previousBand),
                  isValid(candidate, frameHeight: frameHeight) else {
                return nil
            }
            return candidate
        }

        if let consensus = bestAgreeingGroup(in: bandCandidates, minimumCount: consensusBandCount) {
            return makeEstimate(from: consensus, source: .bandConsensus)
        }

        let fullFrame = findAlignment(current, previous)
            .flatMap { isValid($0, frameHeight: frameHeight) ? $0 : nil }
        return resolve(
            bandCandidates: bandCandidates,
            fullFrameCandidate: fullFrame,
            frameHeight: frameHeight
        )
    }

    // MARK: - Downgrade path

    private func resolve(
        bandCandidates: [ScrollAlignmentCandidate],
        fullFrameCandidate: ScrollAlignmentCandidate?,
        frameHeight: CGFloat
    ) -> ScrollOffsetEstimate? {
        guard let fullFrame = fullFrameCandidate else { return nil }

        // Partial band agreement accepted only when a confident full-frame
        // match points to the same translation. The band average carries the
        // value; the full-frame match only vouches for it.
        if fullFrame.confidence >= validatedBandConfidence,
           let partialConsensus = bestAgreeingGroup(in: bandCandidates, minimumCount: partialConsensusBandCount),
           let bandAverage = average(partialConsensus),
           abs(bandAverage.y - fullFrame.y) <= agreementTolerance {
            return ScrollOffsetEstimate(
                translationY: Int(bandAverage.y.rounded()),
                source: .validatedBandFallback
            )
        }

        guard fullFrame.confidence >= fullFrameConfidence else { return nil }
        return ScrollOffsetEstimate(
            translationY: Int(fullFrame.y.rounded()),
            source: .fullFrameFallback
        )
    }

    // MARK: - Bands

    private func comparisonBands(for image: CGImage) -> [CGRect] {
        let imageHeight = image.height
        guard image.width > 0, imageHeight > 0 else { return [] }

        let bandHeight = min(imageHeight, max(minimumBandHeight, imageHeight / 3))
        let maxOriginY = max(0, imageHeight - bandHeight)

        let origins: [Int]
        if maxOriginY == 0 {
            origins = [0]
        } else {
            origins = (0..<bandCount).map { index in
                let denominator = max(1, bandCount - 1)
                return Int((CGFloat(maxOriginY) * CGFloat(index) / CGFloat(denominator)).rounded())
            }
        }

        return Array(Set(origins)).sorted().map { originY in
            CGRect(x: 0, y: originY, width: image.width, height: bandHeight)
        }
    }

    // MARK: - Consensus helpers

    private func bestAgreeingGroup(
        in candidates: [ScrollAlignmentCandidate],
        minimumCount: Int
    ) -> [ScrollAlignmentCandidate]? {
        var bestGroup: [ScrollAlignmentCandidate] = []

        for candidate in candidates {
            let group = candidates.filter {
                abs($0.y - candidate.y) <= agreementTolerance
            }
            if group.count > bestGroup.count {
                bestGroup = group
            }
        }

        return bestGroup.count >= minimumCount ? bestGroup : nil
    }

    private func makeEstimate(
        from candidates: [ScrollAlignmentCandidate],
        source: ScrollOffsetSource
    ) -> ScrollOffsetEstimate? {
        guard let average = average(candidates) else { return nil }
        return ScrollOffsetEstimate(
            translationY: Int(average.y.rounded()),
            source: source
        )
    }

    private func average(_ candidates: [ScrollAlignmentCandidate]) -> ScrollAlignmentCandidate? {
        guard !candidates.isEmpty else { return nil }
        let count = CGFloat(candidates.count)
        return ScrollAlignmentCandidate(
            x: candidates.reduce(0) { $0 + $1.x } / count,
            y: candidates.reduce(0) { $0 + $1.y } / count,
            confidence: candidates.reduce(0) { $0 + $1.confidence } / Float(candidates.count)
        )
    }

    private func isValid(_ candidate: ScrollAlignmentCandidate, frameHeight: CGFloat) -> Bool {
        let maximumVerticalMovement = frameHeight * (1 - minimumOverlapFraction)
        return abs(candidate.x) <= maximumHorizontalMovement
            && abs(candidate.y) <= maximumVerticalMovement
    }

    // MARK: - Vision bridge

    private static func findAlignmentViaVision(
        current: CGImage,
        previous: CGImage
    ) -> ScrollAlignmentCandidate? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        let handler = VNImageRequestHandler(cgImage: current, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }

        return ScrollAlignmentCandidate(
            x: observation.alignmentTransform.tx,
            y: observation.alignmentTransform.ty,
            confidence: observation.confidence
        )
    }
}
