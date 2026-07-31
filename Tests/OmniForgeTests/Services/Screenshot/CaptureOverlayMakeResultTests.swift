import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

/// 编辑器 makeResult 须按捕获入口填充 mode / selection / targetScreen。
@MainActor
final class CaptureOverlayMakeResultTests: XCTestCase {

    func test_regionMakeResult_isAllInOneWithSelection() throws {
        let image = makeImage(width: 40, height: 30)
        let target = CaptureTargetScreen(
            displayID: 7,
            frameInAppKitPoints: CGRect(x: 100, y: 200, width: 1440, height: 900),
            pointPixelScale: 2
        )
        // SelectionView 局部选区（左下原点，相对屏 frame）
        let localRect = CGRect(x: 50, y: 80, width: 200, height: 120)

        let result = try XCTUnwrap(
            CaptureOverlayController.buildScreenshotResult(
                from: image,
                mode: .allInOne,
                targetScreen: target,
                selectionViewLocalRect: localRect
            )
        )

        XCTAssertEqual(result.mode, .allInOne)
        XCTAssertEqual(result.targetScreen.displayID, 7)
        XCTAssertEqual(result.targetScreen.pointPixelScale, 2, accuracy: 0.001)
        XCTAssertNil(result.windowInfo)

        let selection = try XCTUnwrap(result.selection)
        XCTAssertEqual(selection.targetScreen.displayID, 7)
        // 局部 + frame.origin → AppKit 全局
        XCTAssertEqual(selection.appKitGlobalRect.origin.x, 150, accuracy: 0.001)
        XCTAssertEqual(selection.appKitGlobalRect.origin.y, 280, accuracy: 0.001)
        XCTAssertEqual(selection.appKitGlobalRect.width, 200, accuracy: 0.001)
        XCTAssertEqual(selection.appKitGlobalRect.height, 120, accuracy: 0.001)

        XCTAssertEqual(result.pixelImage.width, 40)
        XCTAssertEqual(result.pixelImage.height, 30)
    }

    func test_fullscreenMakeResult_isFullScreenWithNilSelection() throws {
        let image = makeImage(width: 20, height: 10)
        let target = CaptureTargetScreen(
            displayID: 3,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pointPixelScale: 1
        )

        let result = try XCTUnwrap(
            CaptureOverlayController.buildScreenshotResult(
                from: image,
                mode: .fullScreen,
                targetScreen: target,
                selectionViewLocalRect: nil
            )
        )

        XCTAssertEqual(result.mode, .fullScreen)
        XCTAssertNil(result.selection)
        XCTAssertEqual(result.targetScreen.displayID, 3)
        XCTAssertNil(result.windowInfo)
        XCTAssertEqual(result.pixelImage.width, 20)
        XCTAssertEqual(result.pixelImage.height, 10)
    }

    func test_allInOneWithoutValidSelection_returnsNil() {
        let image = makeImage(width: 10, height: 10)
        let target = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 1
        )
        // 完全在屏外 → CaptureSelection 失败 → allInOne makeResult 必须 nil
        let outside = CGRect(x: 500, y: 500, width: 20, height: 20)
        let result = CaptureOverlayController.buildScreenshotResult(
            from: image,
            mode: .allInOne,
            targetScreen: target,
            selectionViewLocalRect: outside
        )
        XCTAssertNil(result)
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
}
