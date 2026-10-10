import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

/// 晾衣绳管线钩子替身：记录排除集登记与挂绳调用。
private final class FakeClotheslineHooks: ClotheslinePipelineHooks {
    private(set) var noted: [String] = []
    private(set) var hung: [(String, NSPoint?)] = []

    func noteOwnWrite(path: String) { noted.append(path) }
    func hangFromPipeline(path: String, origin: NSPoint?) { hung.append((path, origin)) }
}

/// hang 意图契约：副作用为 save → hangOnLine；写盘登记排除集；既有意图行为不变。
@MainActor
final class ScreenshotHangIntentTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - sideEffects

    func test_sideEffects_forHang_isSaveThenHangOnLine() throws {
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .hang), [.save, .hangOnLine])
    }

    func test_sideEffects_existingIntents_unchanged() throws {
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .copy), [.copy])
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .save), [.save])
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .pin), [.pin])
        XCTAssertThrowsError(try ScreenshotResultPipeline.sideEffects(for: .drag))
    }

    // MARK: - run(hang)

    func test_run_hang_savesThenNotesThenHangs() throws {
        let saver = FakeScreenshotSaver()
        let hooks = FakeClotheslineHooks()
        let pipeline = makePipeline(saver: saver)
        pipeline.clotheslineHooks = hooks
        let result = try makeResult()

        let outcome = try pipeline.run(result: result, intent: .hang)

        XCTAssertEqual(outcome.savedFilePath, saver.stubbedURL.path)
        // save 落盘即登记排除集，挂绳发生在登记之后（副作用序 [.save, .hangOnLine]）。
        XCTAssertEqual(hooks.noted, [saver.stubbedURL.path])
        XCTAssertEqual(hooks.hung.map(\.0), [saver.stubbedURL.path])
    }

    func test_run_hang_passesHangOriginToHook() throws {
        let origin = NSPoint(x: 120, y: 340)
        let hooks = FakeClotheslineHooks()
        let pipeline = makePipeline()
        pipeline.clotheslineHooks = hooks

        _ = try pipeline.run(result: try makeResult(), intent: .hang, pinOrigin: nil, hangOrigin: origin)

        XCTAssertEqual(hooks.hung.count, 1)
        XCTAssertEqual(hooks.hung.first?.1, origin)
    }

    func test_run_hang_withoutHooks_stillSaves() throws {
        let saver = FakeScreenshotSaver()
        let pipeline = makePipeline(saver: saver)
        let result = try makeResult()

        let outcome = try pipeline.run(result: result, intent: .hang)

        XCTAssertEqual(outcome.savedFilePath, saver.stubbedURL.path)
        XCTAssertEqual(saver.calls.count, 1)
    }

    // MARK: - save 意图同样登记排除集

    func test_run_save_alsoNotesOwnWriteButDoesNotHang() throws {
        let saver = FakeScreenshotSaver()
        let hooks = FakeClotheslineHooks()
        let pipeline = makePipeline(saver: saver)
        pipeline.clotheslineHooks = hooks

        _ = try pipeline.run(result: try makeResult(), intent: .save)

        XCTAssertEqual(hooks.noted, [saver.stubbedURL.path])
        XCTAssertEqual(hooks.hung.count, 0)
    }

    // MARK: - confirmCache（编辑器确认：复制+缓存+挂绳）

    func test_sideEffects_forConfirmCache_isCopyCacheHang() throws {
        XCTAssertEqual(try ScreenshotResultPipeline.sideEffects(for: .confirmCache),
                       [.copy, .cacheSave, .hangOnLine])
    }

    func test_run_confirmCache_copiesCachesAndHangs() throws {
        let saver = FakeScreenshotSaver()
        let hooks = FakeClotheslineHooks()
        let pipeline = makePipeline(saver: saver)
        pipeline.clotheslineHooks = hooks
        let origin = NSPoint(x: 300, y: 400)

        let outcome = try pipeline.run(result: try makeResult(), intent: .confirmCache,
                                       pinOrigin: nil, hangOrigin: origin)

        XCTAssertTrue(outcome.didCopy)                                  // 复制副作用保留
        XCTAssertEqual(outcome.cachedFilePath, saver.stubbedURL.path)   // 写的是缓存路径
        XCTAssertEqual(hooks.noted, [saver.stubbedURL.path])            // 登记排除集
        XCTAssertEqual(hooks.hung.map(\.0), [saver.stubbedURL.path])    // 挂绳用缓存路径
        XCTAssertEqual(hooks.hung.first?.1, origin)                     // 飞行起点透传
    }

    func test_run_confirmCache_toggleOff_degradesToCopyOnly() throws {
        let suite = "confirm-cache-off-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: UserDefaultsKeys.screenshotClotheslineEditorConfirmHang)
        let saver = FakeScreenshotSaver()
        let hooks = FakeClotheslineHooks()
        let pipeline = ScreenshotResultPipeline(
            userDefaults: defaults,
            encoder: FakeImageOutputEncoder(),
            clipboardWriter: FakeClipboardImageWriter(),
            saver: saver,
            outputConfigurationProvider: {
                ScreenshotOutputConfigurationSnapshot(
                    saveDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                    fileNamePrefix: "Screenshot"
                )
            }
        )
        pipeline.clotheslineHooks = hooks

        let outcome = try pipeline.run(result: try makeResult(), intent: .confirmCache)

        XCTAssertTrue(outcome.didCopy)
        XCTAssertNil(outcome.cachedFilePath)          // 不写缓存
        XCTAssertEqual(saver.calls.count, 0)          // 不落盘
        XCTAssertEqual(hooks.hung.count, 0)           // 不挂绳
    }

    // MARK: - Helpers

    private func makePipeline(
        saver: ScreenshotSaving = FakeScreenshotSaver()
    ) -> ScreenshotResultPipeline {
        ScreenshotResultPipeline(
            encoder: FakeImageOutputEncoder(),
            clipboardWriter: FakeClipboardImageWriter(),
            saver: saver,
            outputConfigurationProvider: {
                ScreenshotOutputConfigurationSnapshot(
                    saveDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                    fileNamePrefix: "Screenshot"
                )
            }
        )
    }

    private func makeResult(width: Int = 4, height: Int = 4) throws -> ScreenshotResult {
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
