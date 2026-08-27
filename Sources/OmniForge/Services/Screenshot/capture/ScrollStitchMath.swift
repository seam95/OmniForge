import Foundation

/// Pure helpers for scroll-frame stitching math (unit-testable without SCKit/Vision).
enum ScrollStitchMath {
    static let defaultMaxFrames = 100

    /// One stitch operation in the capture history. Frames are appended with a
    /// known overlap against the reference frame; reverse scrolling trims rows
    /// off the bottom of the already-stitched image.
    enum StitchStep: Equatable {
        case append(overlap: Int)
        case trimBottom(rows: Int)
    }

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

    /// Replays the step sequence to get the total stitched pixel height.
    /// Trim steps never shrink the result below a single frame height.
    static func totalHeightPixels(frameHeight: Int, steps: [StitchStep]) -> Int {
        guard frameHeight > 0 else { return 0 }
        let floorHeight = frameHeight
        return steps.reduce(frameHeight) { partial, step in
            switch step {
            case let .append(overlap):
                return partial + newRows(height: frameHeight, overlap: overlap)
            case let .trimBottom(rows):
                return max(floorHeight, partial - max(0, rows))
            }
        }
    }

    /// Clamps a reverse-scroll trim so at least one frame height remains.
    /// Returns 0 when the trim would leave nothing meaningful to remove.
    static func clampedTrimRows(
        _ rows: Int,
        currentHeightPixels: Int,
        frameHeight: Int
    ) -> Int {
        guard rows > 0, frameHeight > 0 else { return 0 }
        let removable = currentHeightPixels - frameHeight
        guard removable > 0 else { return 0 }
        return min(rows, removable)
    }

    /// Frame budget gate used by capture loops.
    static func isAtFrameLimit(frameCount: Int, maxFrames: Int = defaultMaxFrames) -> Bool {
        frameCount >= maxFrames
    }
}
