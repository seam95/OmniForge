import Foundation

/// Pure helpers for scroll-frame stitching math (unit-testable without SCKit/Vision).
enum ScrollStitchMath {
    static let defaultMaxFrames = 100

    /// Clamp Vision-derived overlap into a valid row count for a frame of `height`.
    static func clampOverlap(_ overlap: Int, height: Int) -> Int {
        guard height > 0 else { return 0 }
        return max(0, min(height, overlap))
    }

    /// Rows of newly revealed content at the bottom of the current frame.
    static func newRows(height: Int, overlap: Int) -> Int {
        height - clampOverlap(overlap, height: height)
    }

    /// Minimum newly revealed rows required to accept a frame (mirrors ScrollCapturer).
    static func minimumNewRows(height: Int) -> Int {
        max(8, height / 200)
    }

    /// Whether `newRows` is enough to append a frame.
    static func hasEnoughNewContent(height: Int, overlap: Int) -> Bool {
        newRows(height: height, overlap: overlap) >= minimumNewRows(height: height)
    }

    /// Total stitched pixel height given uniform frame heights and per-append overlaps.
    static func totalHeightPixels(frameHeight: Int, overlaps: [Int]) -> Int {
        overlaps.reduce(frameHeight) { partial, overlap in
            partial + newRows(height: frameHeight, overlap: overlap)
        }
    }

    /// Frame budget gate used by capture loops.
    static func isAtFrameLimit(frameCount: Int, maxFrames: Int = defaultMaxFrames) -> Bool {
        frameCount >= maxFrames
    }
}
