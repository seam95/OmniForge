import CoreGraphics
import Foundation

/// Pure builder for CGWindowIDs that must never appear in long-scroll frames.
///
/// Extracted for unit tests and so `ScrollCapturer` sessions always receive a
/// complete exclusion list — especially the host overlay panel that holds the
/// frozen selection snapshot over the live page. The host comes first: the
/// engine captures the region below the first excluded window.
enum ScrollCaptureExclusion {
    /// Collect positive window numbers into unique `CGWindowID`s.
    /// Host overlay first: it covers the capture rect with the freeze bitmap.
    static func excludedWindowIDs(
        hostWindowNumber: Int?,
        hudWindowNumber: Int? = nil,
        previewWindowNumber: Int? = nil,
        toastWindowNumber: Int? = nil
    ) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        var ids: [CGWindowID] = []
        let candidates: [Int?] = [
            hostWindowNumber,
            hudWindowNumber,
            previewWindowNumber,
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
