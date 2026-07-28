import CoreGraphics
import Foundation

/// Pure builder for CGWindowIDs that must never appear in long-scroll frames.
///
/// Extracted for unit tests and so `ScrollCapturer` init (sync first frame) always
/// receives a complete exclusion list — especially the host overlay panel that
/// holds the frozen selection snapshot over the live page.
enum ScrollCaptureExclusion {
    /// Collect positive window numbers into unique `CGWindowID`s.
    /// Host overlay first: it covers the capture rect with the freeze bitmap.
    static func excludedWindowIDs(
        hostWindowNumber: Int?,
        hintWindowNumber: Int? = nil,
        controlWindowNumber: Int? = nil,
        previewWindowNumber: Int? = nil,
        cropWindowNumber: Int? = nil,
        toastWindowNumber: Int? = nil
    ) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        var ids: [CGWindowID] = []
        let candidates: [Int?] = [
            hostWindowNumber,
            hintWindowNumber,
            controlWindowNumber,
            previewWindowNumber,
            cropWindowNumber,
            toastWindowNumber,
        ]
        for number in candidates {
            guard let number, number > 0 else { continue }
            let id = CGWindowID(number)
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }
}
