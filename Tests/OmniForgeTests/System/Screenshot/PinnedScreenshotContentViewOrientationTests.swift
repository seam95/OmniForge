import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

/// 钉图显示方向回归：禁止对正确 CGImage 再做 Y 翻转。
@MainActor
final class PinnedScreenshotContentViewOrientationTests: XCTestCase {
    func test_draw_preservesTopRedBottomBlueOrientation() throws {
        let source = try makeTopRedBottomBlueImage(width: 16, height: 16)
        let view = PinnedScreenshotContentView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        view.image = source

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("bitmapImageRepForCachingDisplay failed")
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // NSBitmapImageRep：(0,0) 在左上。取靠近顶/底中心像素（避开 1pt 边框）。
        let topY = 3
        let bottomY = Int(rep.pixelsHigh) - 4
        let midX = Int(rep.pixelsWide) / 2

        let top = sample(rep, x: midX, y: topY)
        let bottom = sample(rep, x: midX, y: bottomY)

        // 缩放/插值会混入邻行；断言主通道明显占优即可。
        XCTAssertGreaterThan(top.r, top.b + 80, "顶边应偏红，got \(top)")
        XCTAssertGreaterThan(bottom.b, bottom.r + 80, "底边应偏蓝，got \(bottom)")
    }

    // MARK: - Helpers

    private func sample(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var pixel = [Int](repeating: 0, count: 4)
        rep.getPixel(&pixel, atX: x, y: y)
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    /// 直接写 bitmap 行 0 = 顶边：顶红底蓝。
    private func makeTopRedBottomBlueImage(width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                if y == 0 {
                    data[i] = 255; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 255
                } else if y == height - 1 {
                    data[i] = 0; data[i + 1] = 0; data[i + 2] = 255; data[i + 3] = 255
                } else {
                    data[i] = 0; data[i + 1] = 255; data[i + 2] = 0; data[i + 3] = 255
                }
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            struct E: Error {}
            throw E()
        }
        return image
    }
}
