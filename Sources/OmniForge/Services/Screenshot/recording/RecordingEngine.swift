import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum ScreenRecordingFormat: String, CaseIterable {
    case mp4
    case gif

    var fileExtension: String { rawValue }

    var displayName: String {
        let strings = L10n().s
        switch self {
        case .mp4: return strings.recordingFormatMP4
        case .gif: return strings.recordingFormatGIF
        }
    }
}

enum RecordingSavePreference: String, CaseIterable {
    case manual
    case gif
    case mp4

    var displayName: String {
        let strings = L10n().s
        switch self {
        case .manual: return strings.recordingFormatManual
        case .gif: return strings.recordingFormatGIF
        case .mp4: return strings.recordingFormatMP4
        }
    }

    var format: ScreenRecordingFormat? {
        switch self {
        case .manual: return nil
        case .gif: return .gif
        case .mp4: return .mp4
        }
    }
}

typealias RecordingProgressCallback = (_ seconds: Int) -> Void
typealias RecordingCompletionCallback = (_ url: URL?, _ error: Error?) -> Void

/// Captures a screen region via ScreenCaptureKit and encodes H.264 MP4 with AVAssetWriter.
/// Pause duration is deducted from presentation timestamps so the written timeline is continuous.
///
/// State, writer, and frame handling are owned by `recordingQueue`. Completion is delivered
/// exactly once per session (`didFinishSession`).
final class RecordingEngine: NSObject {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case stopping
    }

    /// Mutable only on `recordingQueue`. Prefer `currentState` / `isActive` off-queue.
    private var state: State = .idle

    /// Synchronized snapshot of session state for callers on any queue (e.g. main cancel).
    var currentState: State {
        var snapshot: State = .idle
        performOnRecordingQueueSync { snapshot = self.state }
        return snapshot
    }

    /// True while the session can accept cancel/stop (recording or paused).
    var isActive: Bool {
        let s = currentState
        return s == .recording || s == .paused
    }

    private let fps: Int
    private let recordingQueue = DispatchQueue(label: "omniforge.recording")
    private let recordingQueueKey = DispatchSpecificKey<UInt8>()
    private let recordingQueueToken: UInt8 = 1

    private var screen: NSScreen?
    private var sourceRect: CGRect = .zero
    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var outputURL: URL?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false

    private var hasWrittenFrame = false
    /// Ensures `onCompletion` runs at most once for the active session.
    private var didFinishSession = false

    private var progressTimer: Timer?
    private var elapsedSeconds = 0
    private var pauseStartTime: Date?
    private var totalPausedDuration: TimeInterval = 0

    var onProgress: RecordingProgressCallback?
    var onCompletion: RecordingCompletionCallback?
    var onPauseChanged: ((Bool) -> Void)?

    init(fps: Int = 30) {
        self.fps = fps
        super.init()
        recordingQueue.setSpecific(key: recordingQueueKey, value: recordingQueueToken)
    }

    func startRecording(rect: NSRect, screen: NSScreen, excludeWindowNumbers: [CGWindowID] = []) {
        performOnRecordingQueueSync {
            guard self.state == .idle else { return }
            // New session attempt; allow exactly one completion (including immediate validation failures).
            self.didFinishSession = false
            guard rect.width > 0, rect.height > 0 else {
                self.failLocked(RecordingError.invalidSelection)
                return
            }

            self.state = .recording
            self.screen = screen
            self.totalPausedDuration = 0
            self.pauseStartTime = nil
            self.hasWrittenFrame = false
            self.sessionStarted = false

            // Convert AppKit screen coords → SCStream top-left source rect relative to the display.
            self.sourceRect = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )

            Task {
                await self.beginCapture(screen: screen, excludeWindowNumbers: excludeWindowNumbers)
            }
        }
    }

    func pauseRecording() {
        performOnRecordingQueueSync {
            guard self.state == .recording else { return }
            self.state = .paused
            self.pauseStartTime = Date()
            DispatchQueue.main.async { [weak self] in
                self?.progressTimer?.invalidate()
                self?.progressTimer = nil
                self?.onPauseChanged?(true)
            }
        }
    }

    func resumeRecording() {
        performOnRecordingQueueSync {
            guard self.state == .paused else { return }
            if let pauseStartTime = self.pauseStartTime {
                self.totalPausedDuration += Date().timeIntervalSince(pauseStartTime)
                self.pauseStartTime = nil
            }
            self.state = .recording
            DispatchQueue.main.async { [weak self] in
                self?.startProgressTimer()
                self?.onPauseChanged?(false)
            }
        }
    }

    func stopRecording() {
        performOnRecordingQueueSync {
            guard self.state == .recording || self.state == .paused else { return }
            self.state = .stopping
            DispatchQueue.main.async { [weak self] in
                self?.progressTimer?.invalidate()
                self?.progressTimer = nil
            }
            Task {
                await self.finalizeCapture()
            }
        }
    }

    func cancelRecording() {
        performOnRecordingQueueSync {
            guard self.state == .recording || self.state == .paused else { return }
            self.state = .stopping
            DispatchQueue.main.async { [weak self] in
                self?.progressTimer?.invalidate()
                self?.progressTimer = nil
            }
            Task {
                await self.cancelCapture()
            }
        }
    }

    // MARK: - Test hooks (no SCStream)

    /// Enters `.recording` without starting capture so fail/cancel completion can be unit-tested.
    func enterRecordingStateForTesting() {
        recordingQueue.sync {
            guard state == .idle else { return }
            didFinishSession = false
            state = .recording
            hasWrittenFrame = false
            sessionStarted = false
            totalPausedDuration = 0
            pauseStartTime = nil
        }
    }

    /// Simulates `SCStreamDelegate.stream(_:didStopWithError:)` without a live stream.
    func simulateStreamFailureForTesting(_ error: Error) {
        fail(error)
    }

    // MARK: - Capture setup

    private func beginCapture(screen: NSScreen, excludeWindowNumbers: [CGWindowID]) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // stop/cancel owns teardown + completion once state leaves the active session.
            guard isActiveSession() else { return }

            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
                fail(RecordingError.noDisplay)
                return
            }

            let excludedWindows = excludeWindowNumbers.compactMap { windowID in
                content.windows.first(where: { $0.windowID == windowID })
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let scale = max(screen.backingScaleFactor, 1)
            let (pixelWidth, pixelHeight) = VideoEncodingSettings.evenDimensions(
                width: sourceRect.width * scale,
                height: sourceRect.height * scale
            )

            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            config.width = pixelWidth
            config.height = pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.showsCursor = true
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = false
            if #available(macOS 14.0, *) {
                config.colorSpaceName = CGColorSpace.sRGB
            }

            let prepared: Bool = try recordingQueue.sync {
                guard self.state == .recording || self.state == .paused else {
                    // stop/cancel already owns completion; do not tear down their resources.
                    return false
                }
                let outputURL = Self.makeOutputURL()
                self.outputURL = outputURL
                try self.prepareWriter(url: outputURL, width: pixelWidth, height: pixelHeight)
                return true
            }
            guard prepared else { return }
            guard isActiveSession() else {
                // stop/cancel owns teardown; leave writer/temp for finalize/cancelCapture.
                return
            }

            let output = RecordingStreamOutput()
            output.onFrame = { [weak self] pixelBuffer, presentationTime in
                self?.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onStoppedWithError = { [weak self] error in
                self?.fail(error)
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: recordingQueue)

            let shouldStart: Bool = recordingQueue.sync {
                guard self.state == .recording || self.state == .paused else {
                    return false
                }
                self.streamOutput = output
                self.stream = stream
                return true
            }
            guard shouldStart else {
                // stop/cancel owns completion; abandon the unstarted stream instance.
                return
            }

            try await stream.startCapture()

            guard isActiveSession() else {
                // User stop/cancel raced with startCapture; finalize/cancel will stop the stream.
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.elapsedSeconds = 0
                self?.onProgress?(0)
                self?.startProgressTimer()
            }
        } catch {
            fail(error)
        }
    }

    private func prepareWriter(url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoEncodingSettings.outputSettings(width: width, height: height, fps: fps)
        )
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else { throw RecordingError.writerSetupFailed }
        writer.add(input)
        writer.startWriting()

        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.sessionStarted = false
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        // sampleHandlerQueue is recordingQueue.
        guard state == .recording else { return }
        writeMP4Frame(pixelBuffer: pixelBuffer, presentationTime: adjustedTime(presentationTime))
    }

    private func writeMP4Frame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let writer = assetWriter,
              let input = videoInput,
              let adaptor = adaptor,
              input.isReadyForMoreMediaData
        else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }

        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            hasWrittenFrame = true
        }
    }

    /// Subtracts accumulated pause wall-clock time from the stream PTS so the MP4 timeline has no gap.
    private func adjustedTime(_ time: CMTime) -> CMTime {
        guard totalPausedDuration > 0 else { return time }
        return CMTimeSubtract(
            time,
            CMTimeMakeWithSeconds(totalPausedDuration, preferredTimescale: time.timescale)
        )
    }

    // MARK: - Teardown

    private func finalizeCapture() async {
        let streamToStop: SCStream? = recordingQueue.sync {
            let existing = self.stream
            self.stream = nil
            self.streamOutput = nil
            return existing
        }
        if let streamToStop {
            try? await streamToStop.stopCapture()
        }
        await finalizeMP4()
    }

    private func cancelCapture() async {
        let streamToStop: SCStream? = recordingQueue.sync {
            let existing = self.stream
            self.stream = nil
            self.streamOutput = nil
            return existing
        }
        if let streamToStop {
            try? await streamToStop.stopCapture()
        }

        recordingQueue.async {
            self.cleanupTemporaryOutputLocked()
            self.completeLocked(url: nil, error: nil)
        }
    }

    private func finalizeMP4() async {
        let snapshot: (writer: AVAssetWriter, input: AVAssetWriterInput, hasFrame: Bool, url: URL?)? =
            recordingQueue.sync {
                guard !self.didFinishSession else { return nil }
                guard let writer = self.assetWriter, let input = self.videoInput else {
                    return nil
                }
                let hasFrame = self.hasWrittenFrame
                let url = self.outputURL
                // Detach before finishWriting so concurrent fail/cancel cannot cancel mid-finish.
                self.assetWriter = nil
                self.videoInput = nil
                self.adaptor = nil
                return (writer, input, hasFrame, url)
            }

        guard let snapshot else {
            // Setup aborted (stop during beginCapture) or session already completed.
            recordingQueue.async {
                guard !self.didFinishSession else { return }
                self.cleanupTemporaryOutputLocked()
                self.completeLocked(url: nil, error: RecordingError.noFrames)
            }
            return
        }

        snapshot.input.markAsFinished()
        await snapshot.writer.finishWriting()

        recordingQueue.async {
            if let error = snapshot.writer.error {
                self.outputURL = snapshot.url
                self.cleanupTemporaryOutputLocked()
                self.completeLocked(url: nil, error: error)
            } else if !snapshot.hasFrame {
                self.outputURL = snapshot.url
                self.cleanupTemporaryOutputLocked()
                self.completeLocked(url: nil, error: RecordingError.noFrames)
            } else {
                self.outputURL = nil
                self.completeLocked(url: snapshot.url, error: nil)
            }
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedSeconds += 1
            self.onProgress?(self.elapsedSeconds)
        }
    }

    private func fail(_ error: Error) {
        performOnRecordingQueue {
            self.failLocked(error)
        }
    }

    private func failLocked(_ error: Error) {
        guard !didFinishSession else { return }
        state = .stopping

        let streamToStop = stream
        stream = nil
        streamOutput = nil

        cleanupTemporaryOutputLocked()

        if let streamToStop {
            Task {
                try? await streamToStop.stopCapture()
            }
        }

        completeLocked(url: nil, error: error)
    }

    private func completeLocked(url: URL?, error: Error?) {
        guard !didFinishSession else { return }
        didFinishSession = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.state = .idle
            self.onCompletion?(url, error)
        }
    }

    private func cleanupTemporaryOutputLocked() {
        let url = outputURL
        assetWriter?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        outputURL = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isActiveSession() -> Bool {
        recordingQueue.sync {
            state == .recording || state == .paused
        }
    }

    private func performOnRecordingQueue(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: recordingQueueKey) != nil {
            body()
        } else {
            recordingQueue.async(execute: body)
        }
    }

    /// Public control paths run synchronously so callers observe state updates immediately.
    private func performOnRecordingQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: recordingQueueKey) != nil {
            body()
        } else {
            recordingQueue.sync(execute: body)
        }
    }

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: Date())
        let token = ProcessInfo.processInfo.globallyUniqueString
            .replacingOccurrences(of: "/", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("omniforge-recording-\(date)-\(token).mp4")
    }

    enum RecordingError: LocalizedError, Equatable {
        case invalidSelection
        case noDisplay
        case noFrames
        case writerSetupFailed

        var errorDescription: String? {
            switch self {
            case .invalidSelection: return "The selected recording area is empty"
            case .noDisplay: return "Could not find the selected display"
            case .noFrames: return "No video frames were recorded"
            case .writerSetupFailed: return "Could not prepare the recording writer"
            }
        }
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStoppedWithError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStoppedWithError?(error)
    }
}
