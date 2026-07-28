import AppKit
import AVFoundation
import XCTest
@testable import OmniForge

final class RecordingEngineSettingsTests: XCTestCase {

    // MARK: - evenDimensions

    func test_evenDimensions_roundsUpToEven() {
        // CapCap formula: ceil then floor-to-even — result is always even and ≥ 2.
        let (w, h) = VideoEncodingSettings.evenDimensions(width: 101.2, height: 50.1)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
        XCTAssertGreaterThanOrEqual(w, 2)
        // 101.2 → ceil 102 → 102; 50.1 → ceil 51 → 50
        XCTAssertEqual(w, 102)
        XCTAssertEqual(h, 50)
    }

    func test_evenDimensions_alreadyEven_unchanged() {
        let (w, h) = VideoEncodingSettings.evenDimensions(width: 100, height: 50)
        XCTAssertEqual(w, 100)
        XCTAssertEqual(h, 50)
    }

    func test_evenDimensions_minimumIsTwo() {
        let (w, h) = VideoEncodingSettings.evenDimensions(width: 0.5, height: 0.1)
        XCTAssertEqual(w, 2)
        XCTAssertEqual(h, 2)
    }

    func test_evenDimensions_oddIntegersFloorToEven() {
        // After ceil (no-op for integers), odd values floor to the previous even.
        let (w, h) = VideoEncodingSettings.evenDimensions(width: 101, height: 99)
        XCTAssertEqual(w, 100)
        XCTAssertEqual(h, 98)
        XCTAssertEqual(w % 2, 0)
        XCTAssertEqual(h % 2, 0)
    }

    // MARK: - bitrate clamp

    func test_bitrate_clampsToMin() {
        let bitrate = VideoEncodingSettings.bitrate(width: 2, height: 2, fps: 1, quality: .high)
        XCTAssertEqual(bitrate, VideoQuality.high.minBitrate)
    }

    func test_bitrate_clampsToMax() {
        let bitrate = VideoEncodingSettings.bitrate(width: 7680, height: 4320, fps: 60, quality: .high)
        XCTAssertEqual(bitrate, VideoQuality.high.maxBitrate)
    }

    func test_bitrate_midRangeIsBetweenMinAndMax() {
        let bitrate = VideoEncodingSettings.bitrate(width: 1920, height: 1080, fps: 30, quality: .high)
        XCTAssertGreaterThanOrEqual(bitrate, VideoQuality.high.minBitrate)
        XCTAssertLessThanOrEqual(bitrate, VideoQuality.high.maxBitrate)
    }

    func test_outputSettings_usesH264AndDimensions() {
        let settings = VideoEncodingSettings.outputSettings(width: 640, height: 480, fps: 30)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .h264)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 640)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 480)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertNotNil(compression?[AVVideoAverageBitRateKey] as? Int)
    }

    // MARK: - format enums

    func test_screenRecordingFormat_extensions() {
        XCTAssertEqual(ScreenRecordingFormat.mp4.fileExtension, "mp4")
        XCTAssertEqual(ScreenRecordingFormat.gif.fileExtension, "gif")
    }

    func test_recordingSavePreference_formatMapping() {
        XCTAssertNil(RecordingSavePreference.manual.format)
        XCTAssertEqual(RecordingSavePreference.gif.format, .gif)
        XCTAssertEqual(RecordingSavePreference.mp4.format, .mp4)
    }

    // MARK: - pure state machine pieces (no SCStream)

    func test_recordingEngine_initialStateIsIdle() {
        let engine = RecordingEngine()
        XCTAssertEqual(engine.currentState, .idle)
        XCTAssertFalse(engine.isActive)
    }

    func test_recordingEngine_enterRecordingState_isActiveViaSynchronizedQuery() {
        let engine = RecordingEngine()
        engine.enterRecordingStateForTesting()
        XCTAssertEqual(engine.currentState, .recording)
        XCTAssertTrue(engine.isActive)
    }

    func test_recordingEngine_startWithEmptyRect_failsInvalidSelection() {
        let engine = RecordingEngine()
        let expectation = expectation(description: "completion for invalid selection")
        var receivedError: Error?

        engine.onCompletion = { url, error in
            receivedError = error
            XCTAssertNil(url)
            expectation.fulfill()
        }

        guard let screen = NSScreen.main else {
            // Headless: cannot construct NSScreen; pure idle path still covered.
            expectation.fulfill()
            wait(for: [expectation], timeout: 0.1)
            return
        }

        engine.startRecording(rect: .zero, screen: screen)
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(engine.currentState, .idle)
        XCTAssertEqual(receivedError as? RecordingEngine.RecordingError, .invalidSelection)
    }

    func test_recordingEngine_pauseResumeStopCancelFromIdle_areNoOps() {
        let engine = RecordingEngine()
        engine.pauseRecording()
        XCTAssertEqual(engine.currentState, .idle)
        engine.resumeRecording()
        XCTAssertEqual(engine.currentState, .idle)
        engine.stopRecording()
        XCTAssertEqual(engine.currentState, .idle)
        engine.cancelRecording()
        XCTAssertEqual(engine.currentState, .idle)
    }

    func test_recordingEngine_streamFailure_completesWithErrorOnce() {
        let engine = RecordingEngine()
        engine.enterRecordingStateForTesting()
        XCTAssertEqual(engine.currentState, .recording)

        let done = expectation(description: "stream failure completion")
        var completionCount = 0
        var receivedError: NSError?

        engine.onCompletion = { url, error in
            completionCount += 1
            receivedError = error as NSError?
            XCTAssertNil(url)
            done.fulfill()
        }

        let streamError = NSError(domain: "OmniForgeTests.Stream", code: 99, userInfo: [
            NSLocalizedDescriptionKey: "simulated stream stop",
        ])
        engine.simulateStreamFailureForTesting(streamError)
        // Second failure must not deliver a second completion.
        engine.simulateStreamFailureForTesting(streamError)

        wait(for: [done], timeout: 2.0)

        // Give a beat for any accidental double-callback.
        let noSecond = expectation(description: "no second completion")
        noSecond.isInverted = true
        engine.onCompletion = { _, _ in
            completionCount += 1
            noSecond.fulfill()
        }
        wait(for: [noSecond], timeout: 0.2)

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(receivedError?.domain, "OmniForgeTests.Stream")
        XCTAssertEqual(receivedError?.code, 99)
        XCTAssertEqual(engine.currentState, .idle)
    }

    func test_recordingEngine_cancelDuringActiveSession_completesOnceWithoutError() {
        let engine = RecordingEngine()
        engine.enterRecordingStateForTesting()

        let done = expectation(description: "cancel completion")
        var completionCount = 0

        engine.onCompletion = { url, error in
            completionCount += 1
            XCTAssertNil(url)
            XCTAssertNil(error)
            done.fulfill()
        }

        engine.cancelRecording()
        engine.cancelRecording()

        wait(for: [done], timeout: 2.0)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(engine.currentState, .idle)
    }

    // MARK: - GIFEncoder

    func test_gifEncoder_targetFPS_clampedTo15() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniforge-gif-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = GIFEncoder(url: url, fps: 60, sourceFPS: 30)
        XCTAssertEqual(encoder.clampedTargetFPS, 15)
        XCTAssertFalse(encoder.finish())
    }
}
