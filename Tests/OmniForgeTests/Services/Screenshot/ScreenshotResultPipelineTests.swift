import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

/// `ScreenshotResultPipeline` 契约：copy / save / pin 成功与失败，drag 仍未实现。
@MainActor
final class ScreenshotResultPipelineTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - sideEffects

    func test_sideEffects_mapping_unchanged() throws {
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .copy), [.copy])
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .save), [.save])
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .pin), [.pin])
        XCTAssertThrowsError(try ScreenshotResultPipeline.sideEffects(for: .drag)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .intentNotImplemented(.drag))
        }
    }

    // MARK: - copy

    func test_run_copy_success_writesClipboard() throws {
        let encoder = FakeImageOutputEncoder()
        let clipboard = FakeClipboardImageWriter()
        let saver = FakeScreenshotSaver()
        let pipeline = makePipeline(encoder: encoder, clipboard: clipboard, saver: saver)
        let result = try makeResult(width: 4, height: 3)

        let outcome = try pipeline.run(result: result, intent: .copy)

        XCTAssertTrue(outcome.didCopy)
        XCTAssertNil(outcome.savedFilePath)
        XCTAssertFalse(outcome.didPin)
        XCTAssertNil(outcome.pinnedID)
        XCTAssertEqual(encoder.syncCalls.count, 1)
        XCTAssertEqual(encoder.syncCalls[0].quality, .original)
        XCTAssertEqual(encoder.syncCalls[0].pixelSize.width, 4, accuracy: 0.001)
        XCTAssertEqual(encoder.syncCalls[0].pixelSize.height, 3, accuracy: 0.001)
        XCTAssertEqual(clipboard.writes.count, 1)
        XCTAssertEqual(clipboard.writes[0], encoder.stubbedOutput)
        XCTAssertEqual(saver.calls.count, 0)
    }

    func test_run_copy_clipboardFailure_throwsPasteboardWriteFailed() throws {
        let encoder = FakeImageOutputEncoder()
        let clipboard = FakeClipboardImageWriter()
        clipboard.nextResult = false
        let pipeline = makePipeline(encoder: encoder, clipboard: clipboard)
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .copy)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .pasteboardWriteFailed)
        }
        XCTAssertEqual(encoder.syncCalls.count, 1)
        XCTAssertEqual(clipboard.writes.count, 1)
    }

    func test_run_copy_encodeFailure_throwsEncodingFailed() throws {
        let encoder = FakeImageOutputEncoder()
        encoder.errorToThrow = ImageOutputEncodingError.encodingFailed
        let clipboard = FakeClipboardImageWriter()
        let pipeline = makePipeline(encoder: encoder, clipboard: clipboard)
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .copy)) { error in
            guard case let .encodingFailed(message)? = error as? ScreenshotPipelineError else {
                return XCTFail("期望 encodingFailed，得到 \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(clipboard.writes.count, 0)
    }

    // MARK: - save

    func test_run_save_success_callsSaverWithConfig() throws {
        let encoder = FakeImageOutputEncoder()
        let clipboard = FakeClipboardImageWriter()
        let saver = FakeScreenshotSaver()
        let targetDir = URL(fileURLWithPath: "/tmp/omniforge-pipeline-test", isDirectory: true)
        saver.stubbedURL = targetDir.appendingPathComponent("MyShot-20240101-000000.png")
        let pipeline = makePipeline(
            encoder: encoder,
            clipboard: clipboard,
            saver: saver,
            config: ScreenshotOutputConfigurationSnapshot(
                saveDirectory: targetDir,
                fileNamePrefix: "MyShot"
            )
        )
        let result = try makeResult(width: 8, height: 6)

        let outcome = try pipeline.run(result: result, intent: .save)

        XCTAssertFalse(outcome.didCopy)
        XCTAssertEqual(outcome.savedFilePath, saver.stubbedURL.path)
        XCTAssertFalse(outcome.didPin)
        XCTAssertEqual(encoder.syncCalls.count, 1)
        XCTAssertEqual(encoder.syncCalls[0].quality, .original)
        XCTAssertEqual(clipboard.writes.count, 0)
        XCTAssertEqual(saver.calls.count, 1)
        XCTAssertEqual(saver.calls[0].quality, .original)
        XCTAssertEqual(saver.calls[0].directory, targetDir)
        XCTAssertEqual(saver.calls[0].fileName?.hasPrefix("MyShot-"), true)
        XCTAssertEqual(saver.calls[0].fileName?.hasSuffix(".png"), true)
        XCTAssertEqual(saver.calls[0].output, encoder.stubbedOutput)
    }

    func test_run_save_writeFailure_mapsToPipelineError() throws {
        let saver = FakeScreenshotSaver()
        saver.errorToThrow = ScreenshotSavingError.writeFailed("/tmp/x.png")
        let pipeline = makePipeline(saver: saver)
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .save)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .writeFailed("/tmp/x.png"))
        }
    }

    func test_run_save_directoryFailure_mapsToPipelineError() throws {
        let saver = FakeScreenshotSaver()
        saver.errorToThrow = ScreenshotSavingError.directoryCreationFailed("/tmp/missing")
        let pipeline = makePipeline(saver: saver)
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .save)) { error in
            XCTAssertEqual(
                error as? ScreenshotPipelineError,
                .directoryCreationFailed("/tmp/missing")
            )
        }
    }

    func test_run_save_emptyPayload_mapsToSaveEmptyPayload() throws {
        let saver = FakeScreenshotSaver()
        saver.errorToThrow = ScreenshotSavingError.emptyPayload
        let pipeline = makePipeline(saver: saver)
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .save)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .saveEmptyPayload)
        }
    }

    // MARK: - pin

    func test_run_pin_success_callsPinServiceWithOrigin() throws {
        let pin = FakePinService()
        let fixedID = UUID()
        pin.nextID = fixedID
        let encoder = FakeImageOutputEncoder()
        let clipboard = FakeClipboardImageWriter()
        let saver = FakeScreenshotSaver()
        let pipeline = makePipeline(encoder: encoder, clipboard: clipboard, saver: saver)
        pipeline.pinService = pin
        let result = try makeResult(width: 10, height: 5)
        let origin = NSPoint(x: 120, y: 340)

        let outcome = try pipeline.run(result: result, intent: .pin, pinOrigin: origin)

        XCTAssertTrue(outcome.didPin)
        XCTAssertEqual(outcome.pinnedID, fixedID)
        XCTAssertFalse(outcome.didCopy)
        XCTAssertNil(outcome.savedFilePath)
        XCTAssertEqual(pin.pinnedResults.count, 1)
        XCTAssertEqual(pin.pinnedOrigins, [origin])
        // pin 不需要编码剪贴板/保存
        XCTAssertEqual(encoder.syncCalls.count, 0)
        XCTAssertEqual(clipboard.writes.count, 0)
        XCTAssertEqual(saver.calls.count, 0)
    }

    func test_run_pin_missingService_throws() throws {
        let pipeline = makePipeline()
        pipeline.pinService = nil
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .pin)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .pinServiceUnavailable)
        }
    }

    func test_run_pin_serviceThrows_propagates() throws {
        let pin = FakePinService()
        pin.errorToThrow = ScreenshotPipelineError.pinFailed("boom")
        let pipeline = makePipeline()
        pipeline.pinService = pin
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .pin)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .pinFailed("boom"))
        }
    }

    // MARK: - drag 回归

    /// 非「失败测试」：桩阶段即通过；实现 copy/save/pin 后仍须拒绝 drag。
    func test_run_drag_stillNotImplemented() throws {
        let pipeline = makePipeline()
        let result = try makeResult()

        XCTAssertThrowsError(try pipeline.run(result: result, intent: .drag)) { error in
            XCTAssertEqual(error as? ScreenshotPipelineError, .intentNotImplemented(.drag))
        }
    }

    // MARK: - runAsync

    func test_runAsync_copy_delegatesToRun() async throws {
        let encoder = FakeImageOutputEncoder()
        let clipboard = FakeClipboardImageWriter()
        let pipeline = makePipeline(encoder: encoder, clipboard: clipboard)
        let result = try makeResult()

        let outcome = try await pipeline.runAsync(result: result, intent: .copy)

        XCTAssertTrue(outcome.didCopy)
        XCTAssertEqual(clipboard.writes.count, 1)
    }

    // MARK: - Helpers

    private func makePipeline(
        encoder: ImageOutputEncoding = FakeImageOutputEncoder(),
        clipboard: ClipboardImageWriting = FakeClipboardImageWriter(),
        saver: ScreenshotSaving = FakeScreenshotSaver(),
        config: ScreenshotOutputConfigurationSnapshot = ScreenshotOutputConfigurationSnapshot(
            saveDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            fileNamePrefix: "Screenshot"
        )
    ) -> ScreenshotResultPipeline {
        ScreenshotResultPipeline(
            encoder: encoder,
            clipboardWriter: clipboard,
            saver: saver,
            outputConfigurationProvider: { config }
        )
    }

    private func makeResult(width: Int = 20, height: Int = 10) throws -> ScreenshotResult {
        let image = try makeCGImage(width: width, height: height)
        let screen = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pointPixelScale: 2
        )
        return try ScreenshotResult(
            mode: .fullScreen,
            targetScreen: screen,
            selection: nil,
            timestamp: fixedDate,
            pixelImage: image,
            windowInfo: nil
        )
    }

    private func makeCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            struct MakeImageError: Error {}
            throw MakeImageError()
        }
        return image
    }
}
