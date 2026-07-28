import AppKit
import XCTest
@testable import OmniForge

final class NSColorHexTests: XCTestCase {
    func test_hexString_fromPureColors() {
        XCTAssertEqual(NSColor(red: 0, green: 0, blue: 0, alpha: 1).hexString, "#000000")
        XCTAssertEqual(NSColor(red: 1, green: 1, blue: 1, alpha: 1).hexString, "#FFFFFF")
        XCTAssertEqual(NSColor(red: 1, green: 0, blue: 0, alpha: 1).hexString, "#FF0000")
        XCTAssertEqual(NSColor(red: 0, green: 0, blue: 1, alpha: 1).hexString, "#0000FF")
    }

    func test_hexString_roundsAndUppercases() {
        // 136/255 ≈ 0.533 → 应四舍五入到 136（0x88）
        let orange = NSColor(srgbRed: 255.0 / 255, green: 136.0 / 255, blue: 0, alpha: 1)
        XCTAssertEqual(orange.hexString, "#FF8800")
    }

    func test_hexString_clampsOutOfRange() {
        // 非 sRGB 或越界分量应被 clamp 到 [0,1]，不输出负数或超 255。
        let color = NSColor(srgbRed: 1.2, green: -0.5, blue: 0.5, alpha: 1)
        XCTAssertEqual(color.hexString, "#FF0080")
    }

    func test_init_hex_sixDigits() {
        let black = NSColor(hex: "#000000")
        XCTAssertNotNil(black)
        XCTAssertEqual(black?.hexString, "#000000")

        let orange = NSColor(hex: "#FF8800")
        XCTAssertEqual(orange?.hexString, "#FF8800")

        // 无 # 前缀也应解析
        XCTAssertEqual(NSColor(hex: "FF8800")?.hexString, "#FF8800")
        XCTAssertEqual(NSColor(hex: "ff8800")?.hexString, "#FF8800")
    }

    func test_init_hex_threeDigits() {
        // 3 位每位扩展为两位：#F0A → #FF00AA
        XCTAssertEqual(NSColor(hex: "#F0A")?.hexString, "#FF00AA")
        XCTAssertEqual(NSColor(hex: "F0A")?.hexString, "#FF00AA")
        XCTAssertEqual(NSColor(hex: "#FFF")?.hexString, "#FFFFFF")
    }

    func test_init_hex_rejectsInvalid() {
        XCTAssertNil(NSColor(hex: ""))
        XCTAssertNil(NSColor(hex: "#"))
        XCTAssertNil(NSColor(hex: "#FF"))      // 长度不符（2 位）
        XCTAssertNil(NSColor(hex: "#12345"))   // 长度不符（5 位）
        XCTAssertNil(NSColor(hex: "#GGGGGG"))  // 非十六进制
        XCTAssertNil(NSColor(hex: "##FFFFFF"))
        XCTAssertNil(NSColor(hex: "FF88 00"))  // 含空格
    }

    func test_roundTrip_hexToColorToHex() {
        for hex in ["#000000", "#FFFFFF", "#FF8800", "#336699", "#ABCDEF", "#0F0F0F"] {
            let color = NSColor(hex: hex)
            XCTAssertNotNil(color)
            XCTAssertEqual(color?.hexString, hex, "往返不一致: \(hex)")
        }
    }
}
