import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import OmniForge

/// 阶段 5 输出子系统测试。
///
/// 覆盖：
/// - ImageOutputEncoder：PNG/TIFF 编码、DPI 还原、质量压缩、错误处理。
/// - ClipboardImageWriter：PNG+TIFF 双写、失败透传。
/// - ScreenshotSaver：时间戳命名、去重、目录创建、.atomic 写盘、错误抛出。
/// - 编辑器输出动作（Fake 驱动）：各动作只执行声明副作用、失败保留状态。
final class OutputSubsystemTests: XCTestCase {

    // MARK: - 辅助

    /// 构造一张指定像素尺寸的彩色 NSImage（带 alpha）。
    /// 用手动填充的 NSBitmapImageRep 保证像素尺寸确定（不受 Retina 缩放影响）。
    private func makeImage(width: Int, height: Int) -> NSImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        // 红色不透明：R=255 G=0 B=0 A=255（RGBA premultiplied）。
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

    // MARK: - ImageOutputEncoder

    func test_encode_original_producesPNGWithCorrectMetadata() throws {
        let encoder = ImageOutputEncoder()
        let image = makeImage(width: 4, height: 2)

        let output = try encoder.encode(image: image, quality: .original)

        XCTAssertEqual(output.fileExtension, "png")
        XCTAssertEqual(output.contentType, "image/png")
        XCTAssertEqual(output.contentTypeUTType, .png)
        XCTAssertEqual(output.pasteboardType, .png)
        XCTAssertEqual(output.pixelSize, NSSize(width: 4, height: 2))
        XCTAssertFalse(output.data.isEmpty)
        // 应是合法 PNG（前 8 字节签名）。
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let prefix = Array(output.data.prefix(8))
        XCTAssertEqual(prefix, signature)
    }

    func test_encode_compressed_producesSmallerOrEqualPNG() throws {
        let encoder = ImageOutputEncoder()
        // 大块单色图，压缩应有效。
        let image = makeImage(width: 64, height: 64)

        let original = try encoder.encode(image: image, quality: .original)
        let compressed = try encoder.encode(image: image, quality: .compressed)

        XCTAssertFalse(compressed.data.isEmpty)
        XCTAssertEqual(compressed.fileExtension, "png")
        XCTAssertLessThanOrEqual(compressed.data.count, original.data.count)
    }

    func test_encode_missingImage_throwsMissingImage() {
        let encoder = ImageOutputEncoder()
        // 无任何 representation 的空图。
        let empty = NSImage(size: NSSize(width: 1, height: 1))

        XCTAssertThrowsError(try encoder.encode(image: empty, quality: .original)) { error in
            XCTAssertEqual(error as? ImageOutputEncodingError, .missingImage)
        }
    }

    func test_encodeAsync_completesOnMainThreadWithSuccess() throws {
        let encoder = ImageOutputEncoder()
        let image = makeImage(width: 2, height: 2)
        let expectation = expectation(description: "async encode")

        encoder.encodeAsync(image: image, quality: .original) { result in
            switch result {
            case .success(let output):
                XCTAssertEqual(output.pixelSize, NSSize(width: 2, height: 2))
            case .failure:
                XCTFail("expected success")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func test_encodeAsync_missingImage_returnsFailure() {
        let encoder = ImageOutputEncoder()
        let empty = NSImage(size: NSSize(width: 1, height: 1))
        let expectation = expectation(description: "async encode failure")

        encoder.encodeAsync(image: empty, quality: .original) { result in
            switch result {
            case .success:
                XCTFail("expected failure")
            case .failure(let error):
                XCTAssertEqual(error as? ImageOutputEncodingError, .missingImage)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - ClipboardImageWriter

    func test_clipboardWriter_clearsAndWritesPNGAndTIFF() {
        let writer = ClipboardImageWriter(pasteboard: SystemPasteboardWriter(pasteboard: .general))
        let output = EncodedImageOutput(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )

        let result = writer.writeImage(output)

        XCTAssertTrue(result)
        // 读取剪贴板确认 PNG 写入。
        let png = NSPasteboard.general.data(forType: .png)
        XCTAssertNotNil(png)
    }

    func test_clipboardWriter_returnsFalseWhenPasteboardSetDataFails() {
        // 用一个总是 setData 失败的 fake PasteboardWriting。
        let failingPasteboard = FailingPasteboardWriter()
        let writer = ClipboardImageWriter(pasteboard: failingPasteboard)
        let output = EncodedImageOutput(
            data: Data([0x89]),
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )

        XCTAssertFalse(writer.writeImage(output))
    }

    // MARK: - ScreenshotSaver

    func test_saver_writesFileAndCreatesDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("il-output-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let saver = ScreenshotSaver()
        let output = EncodedImageOutput(
            data: Data([0x89, 0x50]),
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )

        let url = try saver.save(
            output: output,
            quality: .original,
            fileName: "Shot.png",
            directory: tempDir
        )

        XCTAssertEqual(url.lastPathComponent, "Shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), Data([0x89, 0x50]))
    }

    func test_saver_timestampedNameUsedWhenFileNameNil() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("il-output-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixedDate = Date(timeIntervalSince1970: 0)
        let saver = ScreenshotSaver(now: { fixedDate })
        let output = EncodedImageOutput(
            data: Data([0x00]),
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )

        let url = try saver.save(output: output, quality: .original, fileName: nil, directory: tempDir)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("Screenshot-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".png"))
    }

    func test_saver_deduplicatesCollidingFileNames() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("il-output-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let saver = ScreenshotSaver()
        let output = EncodedImageOutput(
            data: Data([0x01]),
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )

        let first = try saver.save(output: output, quality: .original, fileName: "Dup.png", directory: tempDir)
        let second = try saver.save(output: output, quality: .original, fileName: "Dup.png", directory: tempDir)

        XCTAssertEqual(first.lastPathComponent, "Dup.png")
        XCTAssertEqual(second.lastPathComponent, "Dup-1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func test_saver_emptyPayloadThrows() {
        let saver = ScreenshotSaver()
        let output = EncodedImageOutput(
            data: Data(),
            fileExtension: "png",
            contentType: "image/png",
            contentTypeUTType: .png,
            pasteboardType: .png,
            pixelSize: NSSize(width: 1, height: 1)
        )

        XCTAssertThrowsError(
            try saver.save(output: output, quality: .original, fileName: "x.png", directory: nil)
        ) { error in
            XCTAssertEqual(error as? ScreenshotSavingError, .emptyPayload)
        }
    }

    func test_saver_cleanFileName_appendsExtensionAndStripsSlashes() {
        XCTAssertEqual(ScreenshotSaver.cleanFileName("foo/bar:baz"), "foo-bar-baz.png")
        XCTAssertEqual(ScreenshotSaver.cleanFileName("has.png"), "has.png")
    }

    // MARK: - 编辑器输出动作（Fake 驱动）

    /// confirm 成功：编码 + 剪贴板各一次，回调 image。
    @MainActor
    func test_editor_confirm_success_encodesAndWritesClipboard() throws {
        let encoder = FakeImageOutputEncoder()
        let writer = FakeClipboardImageWriter()
        let saver = FakeScreenshotSaver()
        let pin = FakePinService()
        let image = makeImage(width: 2, height: 2)

        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: image,
            document: AnnotationDocument(),
            encoder: encoder,
            clipboardWriter: writer,
            saver: saver,
            pinService: pin,
            pinResultBuilder: { _ in nil },
            onComplete: { completed = $0 }
        )

        editor.confirm()

        XCTAssertEqual(encoder.syncCalls.count, 1)
        XCTAssertEqual(encoder.syncCalls[0].quality, .original)
        XCTAssertEqual(writer.writes.count, 1)
        XCTAssertEqual(saver.calls.count, 0)
        XCTAssertEqual(pin.pinnedResults.count, 0)
        XCTAssertNotNil(completed)
        XCTAssertNil(editor.lastError)
    }

    /// confirm 剪贴板失败：不调用 onComplete（保留状态），记录错误。
    @MainActor
    func test_editor_confirm_clipboardFailure_keepsStateAndRecordsError() {
        let encoder = FakeImageOutputEncoder()
        let writer = FakeClipboardImageWriter()
        writer.nextResult = false
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            encoder: encoder,
            clipboardWriter: writer,
            saver: FakeScreenshotSaver(),
            pinService: FakePinService(),
            pinResultBuilder: { _ in nil },
            onComplete: { completed = $0 }
        )

        editor.confirm()

        // 失败：不回调（不静默关闭），错误已记录。
        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    /// confirm 编码失败：不调用 onComplete，记录错误。
    @MainActor
    func test_editor_confirm_encodeFailure_keepsState() {
        let encoder = FakeImageOutputEncoder()
        encoder.errorToThrow = ImageOutputEncodingError.encodingFailed
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            encoder: encoder,
            clipboardWriter: FakeClipboardImageWriter(),
            saver: FakeScreenshotSaver(),
            pinService: FakePinService(),
            pinResultBuilder: { _ in nil },
            onComplete: { completed = $0 }
        )

        editor.confirm()

        XCTAssertNil(completed)
        XCTAssertEqual(encoder.syncCalls.count, 1)
        XCTAssertNotNil(editor.lastError)
    }

    /// 合成像素密度须等于点尺寸 × sourceBackingScaleFactor（多屏 DPI 不一致时
    /// 钉住尺寸不被放大/缩小的回归）：像素 200×160、点尺寸 100×80、scale=2 →
    /// 合成图 pixelsWide=200。证明用了源屏 scale，而非 lockFocus 的隐式主屏密度。
    @MainActor
    func test_editor_confirm_compositePixelDensityMatchesSourceBackingScale() throws {
        let encoder = FakeImageOutputEncoder()
        // 像素 200×160 的底图，手动把点尺寸调成 100×80（模拟 2× 截图源屏产物）。
        let baseImage = makeImage(width: 200, height: 160)
        baseImage.size = NSSize(width: 100, height: 80)
        for case let rep as NSBitmapImageRep in baseImage.representations {
            rep.size = NSSize(width: 100, height: 80)
        }

        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: baseImage,
            document: AnnotationDocument(),
            encoder: encoder,
            clipboardWriter: FakeClipboardImageWriter(),
            saver: FakeScreenshotSaver(),
            pinService: FakePinService(),
            pinResultBuilder: { _ in nil },
            sourceBackingScaleFactor: 2,
            onComplete: { completed = $0 }
        )

        editor.confirm()

        XCTAssertEqual(encoder.syncCalls.count, 1)
        // 点尺寸保持源底图尺寸；像素宽 = 100(点) × 2(scale) = 200
        XCTAssertEqual(encoder.syncCalls[0].pixelSize.width, 100, accuracy: 0.001)
        XCTAssertEqual(encoder.syncCalls[0].pixelsWide, 200)
        XCTAssertNotNil(completed)
        XCTAssertNil(editor.lastError)
    }

    /// save 成功：只调 saver（不写剪贴板、不钉图），回调 nil；透传目录与前缀文件名。
    @MainActor
    func test_editor_save_success_onlySaves() {
        let encoder = FakeImageOutputEncoder()
        let writer = FakeClipboardImageWriter()
        let saver = FakeScreenshotSaver()
        let targetDir = URL(fileURLWithPath: "/tmp/inputlock-shot-test", isDirectory: true)
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            encoder: encoder,
            clipboardWriter: writer,
            saver: saver,
            outputConfigurationProvider: {
                ScreenshotOutputConfigurationSnapshot(
                    saveDirectory: targetDir,
                    fileNamePrefix: "MyShot"
                )
            },
            pinService: FakePinService(),
            pinResultBuilder: { _ in nil },
            onComplete: { completed = $0 }
        )

        editor.save()

        XCTAssertEqual(encoder.syncCalls.count, 1)
        XCTAssertEqual(saver.calls.count, 1)
        XCTAssertEqual(saver.calls[0].quality, .original)
        XCTAssertEqual(saver.calls[0].directory, targetDir)
        XCTAssertEqual(saver.calls[0].fileName?.hasPrefix("MyShot-"), true)
        XCTAssertEqual(saver.calls[0].fileName?.hasSuffix(".png"), true)
        XCTAssertEqual(writer.writes.count, 0)
        XCTAssertNil(completed)
        XCTAssertNil(editor.lastError)
    }

    /// save 失败：仍回调 nil（编辑器已 tearDown），但记录错误。
    @MainActor
    func test_editor_save_failure_recordsError() {
        let saver = FakeScreenshotSaver()
        saver.errorToThrow = ScreenshotSavingError.writeFailed("/tmp/x.png")
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            saver: saver,
            onComplete: { completed = $0 }
        )

        editor.save()

        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    /// pin 成功：只调 pinService（不写剪贴板、不保存），回调 nil。
    @MainActor
    func test_editor_pin_success_onlyPins() throws {
        let pin = FakePinService()
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            encoder: FakeImageOutputEncoder(),
            clipboardWriter: FakeClipboardImageWriter(),
            saver: FakeScreenshotSaver(),
            pinService: pin,
            pinResultBuilder: { image in
                guard let cg = image.cgImagePreservingBacking() else { return nil }
                let target = CaptureTargetScreen(
                    displayID: 1,
                    frameInAppKitPoints: CGRect(x: 0, y: 0, width: 2, height: 2),
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
            },
            onComplete: { completed = $0 }
        )

        editor.pin()

        XCTAssertEqual(pin.pinnedResults.count, 1)
        XCTAssertNil(completed)
        XCTAssertNil(editor.lastError)
    }

    /// pin 无 pinService：记录错误（annotationErrorPinNotWired），保留状态。
    @MainActor
    func test_editor_pin_withoutService_recordsError() {
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            pinService: nil,
            onComplete: { completed = $0 }
        )

        editor.pin()

        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    /// pin builder 返回 nil：记录错误（annotationErrorNoResultMetadata）。
    @MainActor
    func test_editor_pin_builderReturnsNil_recordsError() {
        let pin = FakePinService()
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            pinService: pin,
            pinResultBuilder: { _ in nil },
            onComplete: { completed = $0 }
        )

        editor.pin()

        XCTAssertEqual(pin.pinnedResults.count, 0)
        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }

    /// pin service 抛错：记录错误，保留状态。
    @MainActor
    func test_editor_pin_serviceThrows_recordsError() {
        let pin = FakePinService()
        pin.errorToThrow = ScreenshotPipelineError.pinFailed("boom")
        var completed: NSImage?
        let editor = AnnotationEditorController(
            baseImage: makeImage(width: 2, height: 2),
            document: AnnotationDocument(),
            pinService: pin,
            pinResultBuilder: { image in
                guard let cg = image.cgImagePreservingBacking() else { return nil }
                let target = CaptureTargetScreen(
                    displayID: 1,
                    frameInAppKitPoints: CGRect(x: 0, y: 0, width: 2, height: 2),
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
            },
            onComplete: { completed = $0 }
        )

        editor.pin()

        XCTAssertNil(completed)
        XCTAssertNotNil(editor.lastError)
    }
}

// MARK: - 测试专用 PasteboardWriting

/// 始终让 setData/setString/writeObjects 失败的 fake（用于触发剪贴板写入失败路径）。
private final class FailingPasteboardWriter: PasteboardWriting {
    func clearContents() {}
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool { false }
    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool { false }
    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { false }
}
