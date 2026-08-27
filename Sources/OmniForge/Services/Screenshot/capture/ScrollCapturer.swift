import AppKit
import Foundation
import os.log

/// Captures successive frames of a screen region and stitches them into a
/// long screenshot using Vision translational registration.
final class ScrollCapturer {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "ScrollCapturer")

    private struct ImageFormat {
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let bitmapInfo: CGBitmapInfo
        let colorSpace: CGColorSpace
    }

    private struct CapturedFrame {
        let image: NSImage
        let bitmap: BitmapData
    }

    /// Result of a single capture attempt, used by auto-scroll to decide
    /// whether the page kept producing fresh content or has bottomed out.
    enum FrameOutcome: Equatable {
        /// A new frame with fresh content was stitched in.
        case appended
        /// Reverse scrolling trimmed rows off the stitched image.
        case trimmed
        /// The frame was a duplicate, too similar, or failed — no progress.
        case noNewContent
        /// The frame budget is exhausted; capturing should stop.
        case atFrameLimit

        var diagnosticName: String {
            switch self {
            case .appended: return "appended"
            case .trimmed: return "trimmed"
            case .noNewContent: return "no-new-content"
            case .atFrameLimit: return "at-frame-limit"
            }
        }
    }

    /// Sync capture bridge used by the stitcher (test-injectable).
    typealias RegionCapture = (
        _ rect: CGRect,
        _ displayID: CGDirectDisplayID,
        _ scaleFactor: CGFloat,
        _ excludingWindowIDs: [CGWindowID],
        _ timeout: TimeInterval
    ) -> NSImage?

    var onPreviewUpdated: ((NSImage) -> Void)?

    private let captureRect: CGRect
    private let displayID: CGDirectDisplayID
    private let scaleFactor: CGFloat
    private let excludedWindowIDs: [CGWindowID]
    private let capture: RegionCapture
    private let captureQueue = DispatchQueue(label: "com.omniforge.scroll-capture", qos: .userInitiated)
    private let maxFrames: Int
    private let diagnosticID: String
    private let settledCaptureTimeout: TimeInterval = 1.5
    private let offsetEstimator: ScrollOffsetEstimating

    private var frames: [CapturedFrame] = []
    /// Stitch history shared by the live preview and the final stitch replay:
    /// appended frames (with overlap) plus reverse-scroll bottom trims.
    private var steps: [ScrollStitchMath.StitchStep] = []
    /// Registration baseline. Updated on append and on executed reverse trims;
    /// the first reverse signal keeps the old baseline so the next reverse
    /// frame reports the cumulative scroll-back.
    private var referenceFrame: CapturedFrame?
    private var hasPendingReverseOffset = false
    private var captureAttemptCount = 0
    private var consecutiveNoNewContentCount = 0

    // Sticky element exclusion state (scrollbar / sticky header).
    private var scrollbarWidthPx: Int = 0
    private var scrollbarDetected: Bool = false
    private var stickyHeaderPx: Int = 0
    private var stickyHeaderDetectionDone: Bool = false
    private var stickyHeaderSamplesTaken: Int = 0

    // Incremental preview state
    private var previewBitmap: BitmapData?
    private var previewHeightPixels: Int = 0
    private var previewScale: CGFloat = 1
    private var previewPointWidth: CGFloat = 0

    /// - Parameters:
    ///   - rect: capture region in global CG coordinates.
    ///   - displayID: target display.
    ///   - scaleFactor: screen backing scale.
    ///   - excludingWindowIDs: window IDs omitted from every frame (e.g. hint toast).
    ///   - maxFrames: hard frame budget (default 100).
    ///   - captureClient: used when `capture` is not injected.
    ///   - capture: injectable sync capture bridge for tests / custom paths.
    ///   - offsetEstimator: frame-to-frame registration (band consensus by default).
    init(
        rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID] = [],
        maxFrames: Int = ScrollStitchMath.defaultMaxFrames,
        captureClient: ScreenCaptureClient? = nil,
        capture: RegionCapture? = nil,
        offsetEstimator: ScrollOffsetEstimating? = nil,
        diagnosticID: String? = nil
    ) {
        self.captureRect = rect
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.excludedWindowIDs = excludingWindowIDs
        self.maxFrames = max(1, maxFrames)
        self.diagnosticID = diagnosticID ?? String(UUID().uuidString.prefix(8))
        self.offsetEstimator = offsetEstimator ?? VisionBandOffsetEstimator()

        if let capture {
            self.capture = capture
        } else if let captureClient {
            self.capture = { rect, displayID, scale, excluding, timeout in
                Self.captureViaClient(
                    captureClient,
                    rect: rect,
                    displayID: displayID,
                    scaleFactor: scale,
                    excludingWindowIDs: excluding,
                    timeout: timeout
                )
            }
        } else {
            let client = ScreenCaptureKitClient()
            self.capture = { rect, displayID, scale, excluding, timeout in
                Self.captureViaClient(
                    client,
                    rect: rect,
                    displayID: displayID,
                    scaleFactor: scale,
                    excludingWindowIDs: excluding,
                    timeout: timeout
                )
            }
        }

        log(
            "init-begin",
            metadata: [
                "captureRect": Self.diagnosticRect(rect),
                "displayID": displayID,
                "scaleFactor": Self.diagnosticNumber(scaleFactor),
                "excludedWindowIDs": excludingWindowIDs.map { String($0) }.joined(separator: ","),
            ]
        )

        // First frame: use a longer timeout so init does not fail on cold SCKit.
        if
            let image = self.capture(rect, displayID, scaleFactor, excludingWindowIDs, 3.0),
            let bitmap = bitmapData(from: image)
        {
            let firstFrame = CapturedFrame(image: image, bitmap: bitmap)
            frames.append(firstFrame)
            referenceFrame = firstFrame
            log(
                "init-first-frame",
                metadata: [
                    "imageSize": Self.diagnosticSize(image.size),
                    "bitmap": Self.diagnosticBitmap(bitmap),
                ]
            )
            initPreview(from: firstFrame)
        } else {
            log("init-first-frame-failed")
        }
    }

    /// Convenience initializer matching CapCap's screen-based call sites.
    convenience init(
        rect: CGRect,
        screen: NSScreen,
        excludingWindowIDs: [CGWindowID] = [],
        maxFrames: Int = ScrollStitchMath.defaultMaxFrames,
        captureClient: ScreenCaptureClient? = nil,
        capture: RegionCapture? = nil,
        offsetEstimator: ScrollOffsetEstimating? = nil,
        diagnosticID: String? = nil
    ) {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
        self.init(
            rect: rect,
            displayID: displayID,
            scaleFactor: screen.backingScaleFactor,
            excludingWindowIDs: excludingWindowIDs,
            maxFrames: maxFrames,
            captureClient: captureClient,
            capture: capture,
            offsetEstimator: offsetEstimator,
            diagnosticID: diagnosticID
        )
    }

    func stopAndStitch(completion: @escaping (NSImage?) -> Void) {
        log("stop-and-stitch-enter")
        captureQueue.async {
            var result: NSImage?

            // One last frame so the final scrolled state is never missed.
            let finalFrameOutcome = self.captureFrame(expectedShiftPoints: 0)
            self.log(
                "stop-and-stitch-final-frame",
                metadata: ["outcome": finalFrameOutcome.diagnosticName]
            )

            guard !self.frames.isEmpty else {
                self.log("stop-and-stitch-no-frames")
                result = nil
                self.log("stop-and-stitch-leave")
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }

            if self.frames.count == 1 {
                self.log("stop-and-stitch-single-frame")
                result = self.frames[0].image
                self.log("stop-and-stitch-leave")
                DispatchQueue.main.async {
                    completion(result)
                }
                return
            }

            self.log("final-stitch-begin")
            result = self.stitchAcceptedFrames()
            self.log(
                "final-stitch-end",
                metadata: [
                    "result": result.map { Self.diagnosticSize($0.size) } ?? "nil",
                ]
            )

            self.log("stop-and-stitch-leave")
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Captures a frame synchronously and reports the outcome. Used by the
    /// auto-scroll loop: it scrolls a fixed step, then calls this to learn
    /// whether the step revealed new content (keep going) or not (page end).
    func captureSynchronously(expectedShiftPoints: CGFloat) -> FrameOutcome {
        var outcome: FrameOutcome = .noNewContent
        captureQueue.sync {
            outcome = captureFrame(expectedShiftPoints: expectedShiftPoints)
        }
        return outcome
    }

    // MARK: - Sync capture bridge

    /// Bridge async `ScreenCaptureClient` to a semaphore + `Task.detached`
    /// so the stitcher can run off the main thread without deadlocking.
    private static func captureViaClient(
        _ client: ScreenCaptureClient,
        rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID],
        timeout: TimeInterval
    ) -> NSImage? {
        let resultBox = CaptureResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task.detached {
            do {
                let cgImage = try await client.captureRegion(
                    rect,
                    displayID: displayID,
                    scaleFactor: scaleFactor,
                    excludingWindowIDs: excludingWindowIDs
                )
                let image = NSImage(cgImage: cgImage, size: NSSize(width: rect.width, height: rect.height))
                resultBox.set(image)
            } catch {
                Self.logger.error("scroll capture failed: \(error.localizedDescription, privacy: .public)")
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(max(1, Int(timeout * 1000))))
        if waitResult == .timedOut {
            task.cancel()
            Self.logger.notice("scroll capture timed out after \(timeout, privacy: .public)s")
            return nil
        }
        return resultBox.get()
    }

    private final class CaptureResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: NSImage?

        func set(_ image: NSImage?) {
            lock.lock()
            self.image = image
            lock.unlock()
        }

        func get() -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }

    // MARK: - Settled capture

    /// Polls until two consecutive captures produce byte-identical raw pixel
    /// data (page settled) or timeout elapses.
    private func captureSettledFrame() -> NSImage? {
        var previousData: Data?
        var lastImage: NSImage?
        var waitNs: UInt64 = 12_000_000
        var captureFailures = 0
        var signatureFailures = 0
        let deadline = Date().addingTimeInterval(settledCaptureTimeout)

        for _ in 0..<20 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let image = capture(
                captureRect,
                displayID,
                scaleFactor,
                excludedWindowIDs,
                remaining
            ) else {
                captureFailures += 1
                sleepUntilDeadline(min(0.03, deadline.timeIntervalSinceNow))
                continue
            }

            guard
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                let signature = cgImage.dataProvider?.data as Data?
            else {
                signatureFailures += 1
                sleepUntilDeadline(min(Double(waitNs) / 1_000_000_000, deadline.timeIntervalSinceNow))
                continue
            }

            if let prev = previousData, prev == signature {
                return image
            }

            previousData = signature
            lastImage = image
            sleepUntilDeadline(min(Double(waitNs) / 1_000_000_000, deadline.timeIntervalSinceNow))
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        log(
            "settled-capture-timeout",
            metadata: [
                "captureFailures": captureFailures,
                "signatureFailures": signatureFailures,
                "hasLastImage": lastImage != nil,
            ]
        )
        return lastImage
    }

    private func sleepUntilDeadline(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }

    @discardableResult
    private func captureFrame(expectedShiftPoints: CGFloat) -> FrameOutcome {
        captureAttemptCount += 1
        let attempt = captureAttemptCount
        log(
            "capture-frame-begin",
            metadata: [
                "attempt": attempt,
                "expectedShiftPoints": Self.diagnosticNumber(expectedShiftPoints),
            ]
        )

        guard frames.count < maxFrames else {
            log("capture-frame-limit", metadata: ["attempt": attempt])
            return .atFrameLimit
        }
        guard
            let image = captureSettledFrame(),
            let bitmap = bitmapData(from: image)
        else {
            logNoNewContent(reason: "capture-or-bitmap-failed", attempt: attempt)
            return .noNewContent
        }

        let candidateFrame = CapturedFrame(image: image, bitmap: bitmap)

        // Nearly-identical check runs against the registration baseline: a
        // settled page keeps producing frames that match the last reference.
        if let baseline = referenceFrame ?? frames.last,
           imagesAreNearlyIdentical(baseline.bitmap, candidateFrame.bitmap) {
            logNoNewContent(
                reason: "nearly-identical",
                attempt: attempt,
                metadata: ["bitmap": Self.diagnosticBitmap(bitmap)]
            )
            return .noNewContent
        }

        guard let reference = referenceFrame ?? frames.last else {
            frames.append(candidateFrame)
            referenceFrame = candidateFrame
            initPreview(from: candidateFrame)
            consecutiveNoNewContentCount = 0
            log(
                "capture-frame-appended",
                metadata: [
                    "attempt": attempt,
                    "reason": "first-frame",
                    "bitmap": Self.diagnosticBitmap(bitmap),
                ]
            )
            return .appended
        }

        let scale = CGFloat(candidateFrame.bitmap.height) / max(candidateFrame.image.size.height, 1)
        let expectedShiftPixels: Int?
        if expectedShiftPoints > 0 {
            expectedShiftPixels = Int((expectedShiftPoints * scale).rounded())
        } else {
            expectedShiftPixels = nil
        }

        let frameHeight = candidateFrame.bitmap.height
        let minimumNewRows = ScrollStitchMath.minimumNewRows(height: frameHeight)

        switch estimateShift(
            previous: reference.bitmap,
            current: candidateFrame.bitmap,
            expectedNewContentPixels: expectedShiftPixels
        ) {
        case let .forward(newContentPx):
            let overlap = ScrollStitchMath.clampOverlap(
                frameHeight - newContentPx,
                height: frameHeight
            )
            let newRows = ScrollStitchMath.newRows(height: frameHeight, overlap: overlap)
            guard newRows >= minimumNewRows else {
                logNoNewContent(
                    reason: "new-rows-below-threshold",
                    attempt: attempt,
                    metadata: [
                        "overlap": overlap,
                        "newRows": newRows,
                        "minimumNewRows": minimumNewRows,
                    ]
                )
                return .noNewContent
            }

            hasPendingReverseOffset = false
            frames.append(candidateFrame)
            steps.append(.append(overlap: overlap))
            appendToPreview(candidateFrame.bitmap, overlapPixels: overlap)
            referenceFrame = candidateFrame
            consecutiveNoNewContentCount = 0
            log(
                "capture-frame-appended",
                metadata: [
                    "attempt": attempt,
                    "overlap": overlap,
                    "newRows": newRows,
                    "bitmap": Self.diagnosticBitmap(bitmap),
                    "previewHeightPixels": previewHeightPixels,
                ]
            )
            return .appended

        case .none:
            hasPendingReverseOffset = false
            logNoNewContent(
                reason: "no-measurable-shift",
                attempt: attempt
            )
            return .noNewContent

        case let .reverse(rows):
            return handleReverseShift(
                candidateFrame,
                rows: rows,
                minimumRows: minimumNewRows,
                attempt: attempt
            )
        }
    }

    /// Reverse-scroll handling. The first reverse signal only arms the pending
    /// flag (keeping the old baseline so the next reverse frame reports the
    /// cumulative scroll-back); the second executes the trim.
    private func handleReverseShift(
        _ candidateFrame: CapturedFrame,
        rows: Int,
        minimumRows: Int,
        attempt: Int
    ) -> FrameOutcome {
        guard rows >= minimumRows else {
            hasPendingReverseOffset = false
            logNoNewContent(
                reason: "reverse-below-threshold",
                attempt: attempt,
                metadata: ["rows": rows, "minimumRows": minimumRows]
            )
            return .noNewContent
        }

        guard hasPendingReverseOffset else {
            hasPendingReverseOffset = true
            logNoNewContent(
                reason: "reverse-pending",
                attempt: attempt,
                metadata: ["rows": rows]
            )
            return .noNewContent
        }

        hasPendingReverseOffset = false
        let trimRows = ScrollStitchMath.clampedTrimRows(
            rows,
            currentHeightPixels: previewHeightPixels,
            frameHeight: candidateFrame.bitmap.height
        )
        referenceFrame = candidateFrame
        guard trimRows > 0 else {
            logNoNewContent(
                reason: "reverse-trim-clamped-to-zero",
                attempt: attempt,
                metadata: ["rows": rows]
            )
            return .noNewContent
        }

        steps.append(.trimBottom(rows: trimRows))
        trimPreviewBottom(trimRows)
        consecutiveNoNewContentCount = 0
        log(
            "capture-frame-trimmed",
            metadata: [
                "attempt": attempt,
                "requestedRows": rows,
                "trimRows": trimRows,
                "previewHeightPixels": previewHeightPixels,
            ]
        )
        return .trimmed
    }

    // MARK: - Incremental Preview

    private func initPreview(from frame: CapturedFrame) {
        previewScale = CGFloat(frame.bitmap.height) / max(frame.image.size.height, 1)
        previewPointWidth = frame.image.size.width

        let initialCapacity = frame.bitmap.height * 10
        guard let output = makeOutputBitmap(from: frame.bitmap, totalHeightPixels: initialCapacity) else {
            log(
                "preview-init-bitmap-failed",
                metadata: ["initialCapacity": initialCapacity]
            )
            return
        }

        copyRows(
            from: frame.bitmap,
            sourceStartRow: 0,
            rowCount: frame.bitmap.height,
            to: output,
            destinationStartRow: 0
        )

        previewBitmap = output
        previewHeightPixels = frame.bitmap.height
        log(
            "preview-init",
            metadata: [
                "initialCapacity": initialCapacity,
                "previewHeightPixels": previewHeightPixels,
            ]
        )
        emitPreviewImage()
    }

    private func appendToPreview(_ bitmap: BitmapData, overlapPixels: Int) {
        guard var previewBitmap else {
            log("preview-append-missing-bitmap")
            return
        }

        let newRows = bitmap.height - overlapPixels
        guard newRows > 0 else {
            log(
                "preview-append-no-rows",
                metadata: [
                    "overlap": overlapPixels,
                    "bitmap": Self.diagnosticBitmap(bitmap),
                ]
            )
            return
        }

        let neededHeight = previewHeightPixels + newRows
        if neededHeight > previewBitmap.height {
            let newCapacity = neededHeight + bitmap.height * 5
            log(
                "preview-grow-begin",
                metadata: [
                    "neededHeight": neededHeight,
                    "newCapacity": newCapacity,
                    "oldCapacity": previewBitmap.height,
                ]
            )
            guard let grown = makeOutputBitmap(from: bitmap, totalHeightPixels: newCapacity) else {
                log("preview-grow-failed", metadata: ["newCapacity": newCapacity])
                return
            }
            copyRows(
                from: previewBitmap,
                sourceStartRow: 0,
                rowCount: previewHeightPixels,
                to: grown,
                destinationStartRow: 0
            )
            self.previewBitmap = grown
            previewBitmap = grown
        }

        copyRows(
            from: bitmap,
            sourceStartRow: overlapPixels,
            rowCount: newRows,
            to: previewBitmap,
            destinationStartRow: previewHeightPixels
        )

        previewHeightPixels += newRows
        log(
            "preview-append",
            metadata: [
                "newRows": newRows,
                "overlap": overlapPixels,
                "previewHeightPixels": previewHeightPixels,
            ]
        )
        emitPreviewImage()
    }

    /// Reverse-scroll trim on the live preview. Rows are laid out top-down and
    /// only the used height shrinks — no pixel copying is needed.
    private func trimPreviewBottom(_ rows: Int) {
        guard previewBitmap != nil, rows > 0 else { return }
        previewHeightPixels -= rows
        log(
            "preview-trim",
            metadata: ["rows": rows, "previewHeightPixels": previewHeightPixels]
        )
        emitPreviewImage()
    }

    private func emitPreviewImage() {
        guard let previewBitmap, previewHeightPixels > 0 else {
            log("preview-emit-skipped")
            return
        }

        let totalHeightPoints = CGFloat(previewHeightPixels) / previewScale
        guard let image = previewBitmap.makeImage(
            pointSize: NSSize(width: previewPointWidth, height: totalHeightPoints),
            pixelHeight: previewHeightPixels
        ) else {
            log(
                "preview-image-failed",
                metadata: [
                    "previewHeightPixels": previewHeightPixels,
                    "totalHeightPoints": Self.diagnosticNumber(totalHeightPoints),
                ]
            )
            return
        }

        log(
            "preview-image-dispatch",
            metadata: [
                "imageSize": Self.diagnosticSize(image.size),
                "pixelHeight": previewHeightPixels,
            ]
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPreviewUpdated?(image)
        }
    }

    // MARK: - Final Stitch

    private func stitchAcceptedFrames() -> NSImage? {
        guard let firstFrame = frames.first else { return nil }

        let bitmapHeight = firstFrame.bitmap.height
        let scale = CGFloat(bitmapHeight) / max(firstFrame.image.size.height, 1)

        let totalHeightPixels = ScrollStitchMath.totalHeightPixels(
            frameHeight: bitmapHeight,
            steps: steps
        )
        let totalHeightPoints = CGFloat(totalHeightPixels) / scale

        guard let stitchedBitmap = makeOutputBitmap(from: firstFrame.bitmap, totalHeightPixels: totalHeightPixels) else {
            log(
                "final-stitch-bitmap-failed",
                metadata: ["totalHeightPixels": totalHeightPixels]
            )
            return firstFrame.image
        }
        log(
            "final-stitch-copy-begin",
            metadata: [
                "frameCount": frames.count,
                "totalHeightPixels": totalHeightPixels,
                "totalHeightPoints": Self.diagnosticNumber(totalHeightPoints),
            ]
        )

        // Replay the step history: appends copy their non-overlapping rows
        // forward, trims rewind the destination so later appends overwrite
        // the tail the user scrolled back past.
        var destinationRow = 0
        var appendIndex = 0

        for step in steps {
            switch step {
            case let .append(overlap):
                let sourceStartRow = appendIndex == 0 ? 0 : overlap
                let rowsToCopy = bitmapHeight - sourceStartRow

                copyRows(
                    from: frames[appendIndex].bitmap,
                    sourceStartRow: sourceStartRow,
                    rowCount: rowsToCopy,
                    to: stitchedBitmap,
                    destinationStartRow: destinationRow
                )

                destinationRow += rowsToCopy
                appendIndex += 1

            case let .trimBottom(rows):
                destinationRow -= rows
            }
        }

        let image = stitchedBitmap.makeImage(
            pointSize: NSSize(width: firstFrame.image.size.width, height: totalHeightPoints),
            pixelHeight: totalHeightPixels
        )
        log(
            "final-stitch-image",
            metadata: [
                "result": image.map { Self.diagnosticSize($0.size) } ?? "nil",
                "destinationRow": destinationRow,
            ]
        )
        return image
    }

    // MARK: - Shift Estimation

    /// Frame-to-frame shift classification consumed by the capture loop.
    private enum FrameShift {
        /// Fresh content revealed at the bottom; `newContentPx` > 0.
        case forward(newContentPx: Int)
        /// Registration failed or produced no measurable offset.
        case none
        /// Content scrolled back up; `rows` > 0 rows should be trimmed.
        case reverse(rows: Int)
    }

    /// Registers the candidate frame against the reference frame after
    /// cropping scrollbar / sticky-header regions, classifying the shift.
    private func estimateShift(
        previous: BitmapData,
        current: BitmapData,
        expectedNewContentPixels: Int?
    ) -> FrameShift {
        let height = min(previous.height, current.height)
        guard height > 0 else {
            log("overlap-empty")
            return .none
        }

        if !scrollbarDetected {
            detectScrollbar(current: current, previous: previous)
        }

        guard let previousCG = previous.makeCGImage(pixelHeight: previous.height),
              let currentCG = current.makeCGImage(pixelHeight: current.height) else {
            log("overlap-cgimage-failed")
            return .none
        }

        let commonWidth = min(currentCG.width, previousCG.width)
        let commonHeight = min(currentCG.height, previousCG.height)
        let cropWidth = max(0, commonWidth - scrollbarWidthPx)
        let cropY = stickyHeaderDetectionDone
            ? min(stickyHeaderPx, commonHeight / 5)
            : 0
        let cropHeight = commonHeight - cropY

        let visionPrevious: CGImage
        let visionCurrent: CGImage
        if cropWidth >= 50 && cropHeight >= 50 && (scrollbarWidthPx > 0 || cropY > 0) {
            let cropRect = CGRect(x: 0, y: cropY, width: cropWidth, height: cropHeight)
            visionPrevious = previousCG.cropping(to: cropRect) ?? previousCG
            visionCurrent = currentCG.cropping(to: cropRect) ?? currentCG
        } else {
            visionPrevious = previousCG
            visionCurrent = currentCG
        }

        var visionMetadata: [String: Any] = [
            "commonWidth": commonWidth,
            "commonHeight": commonHeight,
            "cropWidth": cropWidth,
            "cropY": cropY,
            "cropHeight": cropHeight,
            "scrollbarWidthPx": scrollbarWidthPx,
            "stickyHeaderPx": stickyHeaderPx,
        ]
        // Diagnostic only (mirrors CapCap): not used to bias Vision alignment.
        if let expectedNewContentPixels {
            visionMetadata["expectedNewContentPixels"] = expectedNewContentPixels
        }
        log("vision-registration-begin", metadata: visionMetadata)

        guard let estimate = offsetEstimator.estimate(current: visionCurrent, previous: visionPrevious) else {
            log("vision-registration-no-result", metadata: visionMetadata)
            return .none
        }

        let translationY = estimate.translationY
        visionMetadata["newContentPx"] = translationY
        visionMetadata["source"] = estimate.source.diagnosticName

        if translationY > 5 && !stickyHeaderDetectionDone {
            detectStickyHeader(current: current, previous: previous)
            visionMetadata["stickyHeaderAfterDetection"] = stickyHeaderPx
            visionMetadata["stickyHeaderDetectionDone"] = stickyHeaderDetectionDone
        }

        if translationY > 0 {
            visionMetadata["overlap"] = ScrollStitchMath.clampOverlap(
                height - translationY,
                height: height
            )
        }
        log("vision-registration-end", metadata: visionMetadata)

        if translationY > 0 {
            return .forward(newContentPx: translationY)
        }
        if translationY < 0 {
            return .reverse(rows: -translationY)
        }
        return .none
    }

    // MARK: - Sticky element detection

    private func detectScrollbar(current: BitmapData, previous: BitmapData) {
        defer { scrollbarDetected = true }

        let width = min(current.width, previous.width)
        let height = min(current.height, previous.height)
        guard width > 80, height > 40 else { return }

        let maxScan = min(50, width / 8)
        let sampleStart = height / 5
        let sampleEnd = (height * 4) / 5
        let sampleStep = max(1, (sampleEnd - sampleStart) / 30)

        var detectedWidth = 0
        var sawQuietAfterMoving = false

        for offset in 0..<maxScan {
            let column = width - 1 - offset
            var totalDiff = 0
            var samples = 0

            var row = sampleStart
            while row < sampleEnd {
                let lhs = current.pixel(x: column, y: row)
                let rhs = previous.pixel(x: column, y: row)
                totalDiff +=
                    abs(Int(lhs.r) - Int(rhs.r)) +
                    abs(Int(lhs.g) - Int(rhs.g)) +
                    abs(Int(lhs.b) - Int(rhs.b))
                samples += 1
                row += sampleStep
            }

            guard samples > 0 else { continue }
            let avg = totalDiff / samples

            if avg > 8 {
                detectedWidth = offset + 1
            } else if detectedWidth > 0 {
                sawQuietAfterMoving = true
                break
            }
        }

        if sawQuietAfterMoving && detectedWidth >= 3 && detectedWidth <= 40 {
            scrollbarWidthPx = detectedWidth + 4
        }
        log(
            "scrollbar-detection",
            metadata: [
                "detectedWidth": detectedWidth,
                "committedWidth": scrollbarWidthPx,
                "sawQuietAfterMoving": sawQuietAfterMoving,
            ]
        )
    }

    private func detectStickyHeader(current: BitmapData, previous: BitmapData) {
        let width = min(current.width, previous.width)
        let height = min(current.height, previous.height)
        guard width > 80, height > 40 else {
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-skipped",
                metadata: [
                    "width": width,
                    "height": height,
                ]
            )
            return
        }

        let scanWidth = max(40, width - scrollbarWidthPx)
        let columnStart = width / 10
        let columnEnd = min(scanWidth - 1, (scanWidth * 9) / 10)
        let columnStep = max(1, (columnEnd - columnStart) / 20)

        var firstMovingRow = -1
        for row in 0..<height {
            var totalDiff = 0
            var samples = 0

            var column = columnStart
            while column <= columnEnd {
                let lhs = current.pixel(x: column, y: row)
                let rhs = previous.pixel(x: column, y: row)
                totalDiff +=
                    abs(Int(lhs.r) - Int(rhs.r)) +
                    abs(Int(lhs.g) - Int(rhs.g)) +
                    abs(Int(lhs.b) - Int(rhs.b))
                samples += 1
                column += columnStep
            }

            guard samples > 0 else { continue }
            if totalDiff / samples > 8 {
                firstMovingRow = row
                break
            }
        }

        guard firstMovingRow >= 0 else {
            log("sticky-header-detection-frozen-frame")
            return
        }

        let frozenRows = firstMovingRow
        let maxPlausibleHeader = (height * 6) / 10

        stickyHeaderSamplesTaken += 1

        if frozenRows < 10 {
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-none",
                metadata: ["frozenRows": frozenRows]
            )
            return
        }

        if frozenRows > maxPlausibleHeader {
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-implausible",
                metadata: [
                    "frozenRows": frozenRows,
                    "maxPlausibleHeader": maxPlausibleHeader,
                ]
            )
            return
        }

        if stickyHeaderSamplesTaken == 1 {
            stickyHeaderPx = frozenRows
        } else if abs(frozenRows - stickyHeaderPx) <= 5 {
            stickyHeaderPx = min(stickyHeaderPx, frozenRows)
        } else {
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
            log(
                "sticky-header-detection-unstable",
                metadata: [
                    "frozenRows": frozenRows,
                    "sampleCount": stickyHeaderSamplesTaken,
                ]
            )
            return
        }

        if stickyHeaderSamplesTaken >= 2 {
            stickyHeaderDetectionDone = true
        }
        log(
            "sticky-header-detection-sample",
            metadata: [
                "frozenRows": frozenRows,
                "stickyHeaderPx": stickyHeaderPx,
                "sampleCount": stickyHeaderSamplesTaken,
                "done": stickyHeaderDetectionDone,
            ]
        )
    }

    // MARK: - Image Helpers

    private func logNoNewContent(
        reason: String,
        attempt: Int,
        metadata: [String: Any] = [:]
    ) {
        consecutiveNoNewContentCount += 1
        guard consecutiveNoNewContentCount == 1 || consecutiveNoNewContentCount.isMultiple(of: 5) else {
            return
        }

        var fields = metadata
        fields["attempt"] = attempt
        fields["reason"] = reason
        fields["consecutiveNoNewContent"] = consecutiveNoNewContentCount
        log("capture-frame-no-new-content", metadata: fields)
    }

    private func log(_ event: String, metadata: [String: Any] = [:]) {
        var fields = metadata
        fields["session"] = diagnosticID
        fields["frames"] = frames.count
        fields["steps"] = steps.count
        fields["attempts"] = captureAttemptCount
        fields["previewHeightPixels"] = previewHeightPixels
        let summary = fields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        Self.logger.debug("scroll-stitch \(event, privacy: .public) \(summary, privacy: .public)")
    }

    private static func diagnosticRect(_ rect: CGRect) -> String {
        "x=\(diagnosticNumber(rect.origin.x)) y=\(diagnosticNumber(rect.origin.y)) w=\(diagnosticNumber(rect.width)) h=\(diagnosticNumber(rect.height))"
    }

    private static func diagnosticSize(_ size: NSSize) -> String {
        "w=\(diagnosticNumber(size.width)) h=\(diagnosticNumber(size.height))"
    }

    private static func diagnosticBitmap(_ bitmap: BitmapData) -> String {
        "w=\(bitmap.width) h=\(bitmap.height) bpr=\(bitmap.bytesPerRow)"
    }

    private static func diagnosticNumber(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func imagesAreNearlyIdentical(_ lhs: BitmapData, _ rhs: BitmapData) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return false
        }

        let numCols = min(32, max(16, lhs.width / 20))
        let numRows = min(32, max(16, lhs.height / 20))
        let sampleCols = sampledColumns(width: lhs.width, count: numCols)
        let sampleRows = sampledRows(height: lhs.height, count: numRows)

        var diff = 0
        var comparisons = 0

        for row in sampleRows {
            for col in sampleCols {
                diff += pixelDiff(lhs.pixel(x: col, y: row), rhs.pixel(x: col, y: row))
                comparisons += 1
            }
        }

        guard comparisons > 0 else { return false }
        return diff / comparisons < 3
    }

    private func sampledColumns(width: Int, count: Int) -> [Int] {
        guard width > 0, count > 0 else { return [] }

        let inset = min(max(4, width / 12), max(4, width / 4))
        let lowerBound = min(width - 1, inset)
        let upperBound = max(lowerBound, width - inset - 1)
        let span = max(1, upperBound - lowerBound + 1)

        var result: [Int] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let column = lowerBound + min(span - 1, span * (index * 2 + 1) / max(1, count * 2))
            if result.last != column {
                result.append(column)
            }
        }

        return result
    }

    private func sampledRows(height: Int, count: Int) -> [Int] {
        guard height > 0, count > 0 else { return [] }

        var rows: [Int] = []
        rows.reserveCapacity(count)

        for index in 0..<count {
            let row = min(height - 1, height * (index * 2 + 1) / max(1, count * 2))
            if rows.last != row {
                rows.append(row)
            }
        }

        return rows
    }

    private func pixelDiff(_ lhs: (r: UInt8, g: UInt8, b: UInt8), _ rhs: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
        abs(Int(lhs.r) - Int(rhs.r)) +
        abs(Int(lhs.g) - Int(rhs.g)) +
        abs(Int(lhs.b) - Int(rhs.b))
    }

    private func bitmapData(from image: NSImage) -> BitmapData? {
        guard let rep = image.bitmapImageRepPreservingBacking() else { return nil }
        return BitmapData(rep: rep)
    }

    private func makeOutputBitmap(from source: BitmapData, totalHeightPixels: Int) -> BitmapData? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: totalHeightPixels,
            bitsPerSample: source.rep.bitsPerSample,
            samplesPerPixel: source.rep.samplesPerPixel,
            hasAlpha: source.rep.hasAlpha,
            isPlanar: false,
            colorSpaceName: source.rep.colorSpaceName,
            bitmapFormat: source.rep.bitmapFormat,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        return BitmapData(rep: rep, format: source.imageFormat)
    }

    private func copyRows(
        from source: BitmapData,
        sourceStartRow: Int,
        rowCount: Int,
        to destination: BitmapData,
        destinationStartRow: Int
    ) {
        guard rowCount > 0 else { return }

        let bytesPerRow = min(source.width * source.bytesPerPixelValue, min(source.bytesPerRow, destination.bytesPerRow))

        for rowOffset in 0..<rowCount {
            let sourceOffset = (sourceStartRow + rowOffset) * source.bytesPerRow
            let destinationOffset = (destinationStartRow + rowOffset) * destination.bytesPerRow
            memcpy(
                destination.data.advanced(by: destinationOffset),
                source.data.advanced(by: sourceOffset),
                bytesPerRow
            )
        }
    }

    private final class BitmapData {
        let rep: NSBitmapImageRep
        let data: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let imageFormat: ImageFormat
        private let bytesPerPixel: Int

        init?(rep: NSBitmapImageRep, format: ImageFormat? = nil) {
            guard let data = rep.bitmapData else { return nil }

            let resolvedFormat: ImageFormat
            if let format {
                resolvedFormat = format
            } else {
                let cgImage = rep.cgImage
                guard
                    let cgImage,
                    let colorSpace = cgImage.colorSpace
                else {
                    return nil
                }

                resolvedFormat = ImageFormat(
                    bitsPerComponent: cgImage.bitsPerComponent,
                    bitsPerPixel: cgImage.bitsPerPixel,
                    bitmapInfo: cgImage.bitmapInfo,
                    colorSpace: colorSpace
                )
            }

            self.rep = rep
            self.data = data
            self.bytesPerRow = rep.bytesPerRow
            self.width = rep.pixelsWide
            self.height = rep.pixelsHigh
            self.imageFormat = resolvedFormat
            self.bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        }

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return (0, 0, 0)
            }

            let offset = y * bytesPerRow + x * bytesPerPixel
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        func makeImage(pointSize: NSSize, pixelHeight: Int) -> NSImage? {
            guard let cgImage = makeCGImage(pixelHeight: pixelHeight) else { return nil }
            return NSImage(cgImage: cgImage, size: pointSize)
        }

        func makeCGImage(pixelHeight: Int) -> CGImage? {
            guard pixelHeight > 0, pixelHeight <= height else { return nil }

            let byteCount = pixelHeight * bytesPerRow
            let buffer = UnsafeBufferPointer(start: data, count: byteCount)
            let imageData = Data(buffer: buffer)

            guard let provider = CGDataProvider(data: imageData as CFData) else { return nil }
            return CGImage(
                width: width,
                height: pixelHeight,
                bitsPerComponent: imageFormat.bitsPerComponent,
                bitsPerPixel: imageFormat.bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: imageFormat.colorSpace,
                bitmapInfo: imageFormat.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        var bytesPerPixelValue: Int { bytesPerPixel }
    }
}

// MARK: - NSImage bitmap helper

private extension NSImage {
    /// Highest-resolution bitmap rep, or a freshly drawn one.
    func bitmapImageRepPreservingBacking() -> NSBitmapImageRep? {
        let highestRes = representations
            .compactMap { $0 as? NSBitmapImageRep }
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { lhs, rhs in
                (lhs.pixelsWide * lhs.pixelsHigh) < (rhs.pixelsWide * rhs.pixelsHigh)
            }
        if let highestRes {
            return highestRes
        }

        guard let cgImage = cgImagePreservingBacking() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}
