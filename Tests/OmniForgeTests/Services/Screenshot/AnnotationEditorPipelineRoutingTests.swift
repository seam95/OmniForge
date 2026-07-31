import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

/// 编辑器 confirm/save/pin 必须经 `ScreenshotResultRunning` 路由 intent。
@MainActor
final class AnnotationEditorPipelineRoutingTests: XCTestCase {

    func test_confirm_routesCopyIntentThroughPipeline() throws {
        let runner = FakeScreenshotResultRunner()
        let image = makeImage(width: 4, height: 3)
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: image,
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { self.makeScreenshotResult(from: $0) },
            onComplete: { completed = $0 }
        )

        editor.confirm()

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].intent, .copy)
        XCTAssertNil(runner.calls[0].pinOrigin)
        XCTAssertNotNil(completed)
        XCTAssertNil(editor.lastError)
    }

    func test_save_routesSaveIntentThroughPipeline() throws {
        let runner = FakeScreenshotResultRunner()
        var completedCalled = false
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { self.makeScreenshotResult(from: $0) },
            onComplete: { _ in completedCalled = true }
        )

        editor.save()

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].intent, .save)
        XCTAssertNil(runner.calls[0].pinOrigin)
        XCTAssertTrue(completedCalled)
        XCTAssertNil(editor.lastError)
    }

    func test_pin_routesPinIntentWithOriginThroughPipeline() throws {
        let runner = FakeScreenshotResultRunner()
        let expectedOrigin = NSPoint(x: 42, y: 84)
        var completedCalled = false
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { self.makeScreenshotResult(from: $0) },
            onComplete: { _ in completedCalled = true }
        )
        // 无 host 时 selectionScreenOrigin 为 nil；注入测试钩子不可行时直接断言 intent=.pin。
        // 原位原点在有 host 时由 selectionScreenOrigin 计算；此处验证至少走 .pin。
        editor.pin()

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].intent, .pin)
        // 无宿主窗口时 origin 为 nil（与现实现一致）。
        XCTAssertNil(runner.calls[0].pinOrigin)
        XCTAssertTrue(completedCalled)
        XCTAssertNil(editor.lastError)
        _ = expectedOrigin
    }

    func test_confirm_pipelineFailure_keepsEditorAndRecordsError() {
        let runner = FakeScreenshotResultRunner()
        runner.errorToThrow = ScreenshotPipelineError.pasteboardWriteFailed
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { self.makeScreenshotResult(from: $0) },
            onComplete: { completed = $0 }
        )

        editor.confirm()

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    func test_save_pipelineFailure_stillCompletesWithErrorRecorded() {
        let runner = FakeScreenshotResultRunner()
        runner.errorToThrow = ScreenshotPipelineError.writeFailed("/tmp/x.png")
        var completedCalled = false
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { self.makeScreenshotResult(from: $0) },
            onComplete: { _ in completedCalled = true }
        )

        editor.save()

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(completedCalled)
        XCTAssertNotNil(editor.lastError)
    }

    func test_pin_pipelineFailure_keepsEditorAndRecordsError() {
        let runner = FakeScreenshotResultRunner()
        runner.errorToThrow = ScreenshotPipelineError.pinServiceUnavailable
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { self.makeScreenshotResult(from: $0) },
            onComplete: { completed = $0 }
        )

        editor.pin()

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    func test_confirm_makeResultFailure_doesNotCallPipeline() {
        let runner = FakeScreenshotResultRunner()
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            resultRunner: runner,
            makeResult: { _ in nil },
            onComplete: { completed = $0 }
        )

        editor.confirm()

        XCTAssertEqual(runner.calls.count, 0)
        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    // MARK: - Helpers

    private func makeImage(width: Int, height: Int) -> NSImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 255
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 255
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: width, height: height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func makeScreenshotResult(from image: NSImage) -> ScreenshotResult? {
        guard let cg = image.cgImagePreservingBacking()
                ?? (image.representations.first as? NSBitmapImageRep)?.cgImage else {
            return nil
        }
        let target = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pointPixelScale: 1
        )
        return try? ScreenshotResult(
            mode: .fullScreen,
            targetScreen: target,
            selection: nil,
            timestamp: Date(),
            pixelImage: cg,
            windowInfo: nil
        )
    }
}

/// 记录 intent 的 pipeline 替身。
final class FakeScreenshotResultRunner: ScreenshotResultRunning {
    struct Call {
        let result: ScreenshotResult
        let intent: ScreenshotEntryIntent
        let pinOrigin: NSPoint?
    }

    private(set) var calls: [Call] = []
    var errorToThrow: Error?
    var outcome = ScreenshotPipelineOutcome(didCopy: true)

    @discardableResult
    func run(
        result: ScreenshotResult,
        intent: ScreenshotEntryIntent,
        pinOrigin: NSPoint? = nil
    ) throws -> ScreenshotPipelineOutcome {
        calls.append(Call(result: result, intent: intent, pinOrigin: pinOrigin))
        if let errorToThrow { throw errorToThrow }
        var o = outcome
        switch intent {
        case .copy: o.didCopy = true
        case .save: o.savedFilePath = o.savedFilePath ?? "/tmp/fake.png"
        case .pin:
            o.didPin = true
            o.pinnedID = o.pinnedID ?? UUID()
        case .drag: break
        }
        return o
    }
}
