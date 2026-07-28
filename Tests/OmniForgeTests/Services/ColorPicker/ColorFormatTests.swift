import AppKit
import XCTest
@testable import OmniForge

final class ColorFormatTests: XCTestCase {
    // MARK: HEX

    func test_hex_pureColors() {
        XCTAssertEqual(ColorFormat.hex(from: NSColor(red: 0, green: 0, blue: 0, alpha: 1)), "#000000")
        XCTAssertEqual(ColorFormat.hex(from: NSColor(red: 1, green: 1, blue: 1, alpha: 1)), "#FFFFFF")
        XCTAssertEqual(ColorFormat.hex(from: NSColor(red: 1, green: 0, blue: 0, alpha: 1)), "#FF0000")
    }

    // MARK: RGB

    func test_rgb_pureColors() {
        XCTAssertEqual(ColorFormat.rgb(from: NSColor(red: 0, green: 0, blue: 0, alpha: 1)), "rgb(0, 0, 0)")
        XCTAssertEqual(ColorFormat.rgb(from: NSColor(red: 1, green: 1, blue: 1, alpha: 1)), "rgb(255, 255, 255)")
        XCTAssertEqual(ColorFormat.rgb(from: NSColor(red: 1, green: 0, blue: 0, alpha: 1)), "rgb(255, 0, 0)")
    }

    func test_rgb_roundsToInteger() {
        let orange = NSColor(srgbRed: 255.0 / 255, green: 136.0 / 255, blue: 0, alpha: 1)
        XCTAssertEqual(ColorFormat.rgb(from: orange), "rgb(255, 136, 0)")
    }

    // MARK: HSL — 灰阶

    func test_hsl_grayscale_saturationZero() {
        XCTAssertEqual(ColorFormat.hsl(from: NSColor(red: 0, green: 0, blue: 0, alpha: 1)), "hsl(0, 0%, 0%)")
        XCTAssertEqual(ColorFormat.hsl(from: NSColor(red: 1, green: 1, blue: 1, alpha: 1)), "hsl(0, 0%, 100%)")
        // 中灰 0.5 → 50%
        let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        XCTAssertEqual(ColorFormat.hsl(from: gray), "hsl(0, 0%, 50%)")
    }

    // MARK: HSL — 彩色

    func test_hsl_pureRed() {
        // 纯红：色相 0，饱和度 100%，亮度 50%
        XCTAssertEqual(ColorFormat.hsl(from: NSColor(red: 1, green: 0, blue: 0, alpha: 1)), "hsl(0, 100%, 50%)")
    }

    func test_hsl_pureGreen() {
        // 纯绿：色相 120，饱和度 100%，亮度 50%
        XCTAssertEqual(ColorFormat.hsl(from: NSColor(red: 0, green: 1, blue: 0, alpha: 1)), "hsl(120, 100%, 50%)")
    }

    func test_hsl_pureBlue() {
        // 纯蓝：色相 240，饱和度 100%，亮度 50%
        XCTAssertEqual(ColorFormat.hsl(from: NSColor(red: 0, green: 0, blue: 1, alpha: 1)), "hsl(240, 100%, 50%)")
    }

    // MARK: 归一化

    func test_conversion_normalizesColorSpace() {
        // 即使传入非 sRGB 颜色，转换结果也应基于 sRGB 数值，不崩溃。
        let generic = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        let hex = ColorFormat.hex(from: generic)
        XCTAssertTrue(hex.hasPrefix("#"))
    }

    // MARK: enum dispatch

    func test_format_string_dispatchesCorrectly() {
        let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(ColorFormat.hex.string(from: red), "#FF0000")
        XCTAssertEqual(ColorFormat.rgb.string(from: red), "rgb(255, 0, 0)")
        XCTAssertEqual(ColorFormat.hsl.string(from: red), "hsl(0, 100%, 50%)")
    }
}
