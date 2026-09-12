import XCTest
@testable import OmniForge

/// 看向方向索引纯函数测试：四主方向、16 向中心、半格边界归属、死区与负坐标副屏。
final class PetLookOverlayTests: XCTestCase {
    /// 以 (0, 0) 为中心的 10×10 矩形；指向 (r·sin θ, r·cos θ) 即顺时针 θ 度方向。
    private let rect = CGRect(x: -5, y: -5, width: 10, height: 10)
    private let radius: CGFloat = 100

    /// 顺时针角度 → 期望槽位（正上 0°=0、右 90°=4、下 180°=8、左 270°=12）。
    private func index(degrees: CGFloat) -> Int? {
        let radians = degrees * .pi / 180
        let pointer = CGPoint(x: radius * sin(radians), y: radius * cos(radians))
        return PetLookOverlay.directionIndex(pointer: pointer, petRect: rect)
    }

    // MARK: - 主方向与 16 向中心

    func test_fourCardinalDirections() {
        XCTAssertEqual(index(degrees: 0), 0, "正上")
        XCTAssertEqual(index(degrees: 90), 4, "正右")
        XCTAssertEqual(index(degrees: 180), 8, "正下")
        XCTAssertEqual(index(degrees: 270), 12, "正左")
    }

    func test_allSixteenDirectionCenters() {
        // 每槽中心角 = 22.5° × i。
        for slot in 0..<16 {
            XCTAssertEqual(index(degrees: CGFloat(slot) * 22.5), slot, "槽位 \(slot) 中心角")
        }
    }

    // MARK: - 半格边界

    func test_halfStepBoundariesRoundToNextClockwiseSlot() {
        // 边界角 11.25° + 22.5k 归入顺时针下一格（.rounded() 半值远离零）。
        for slot in 0..<16 {
            let boundary = 11.25 + 22.5 * Double(slot)
            let normalized = boundary < 360 ? boundary : boundary - 360
            XCTAssertEqual(
                index(degrees: CGFloat(normalized)),
                (slot + 1) % 16,
                "边界 \(boundary)° 应归入槽位 \((slot + 1) % 16)"
            )
        }
    }

    func test_boundaryLowerSideStaysInCurrentSlot() {
        // 边界下方一丝（11.24°）仍属当前槽。
        XCTAssertEqual(index(degrees: 11.24), 0)
        XCTAssertEqual(index(degrees: 33.74), 1)
        // 359.99° 恰在 0 槽内（360° 衔接不断裂）；15 槽中心 337.5° 两侧留在 15。
        XCTAssertEqual(index(degrees: 359.99), 0)
        XCTAssertEqual(index(degrees: 344), 15)
        XCTAssertEqual(index(degrees: 331), 15)
    }

    // MARK: - 死区

    func test_pointerInsideRectReturnsNilIncludingBoundary() {
        // 中心、内部、四条边与四角（含边界）都是死区。
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: .zero, petRect: rect))
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 4, y: 4), petRect: rect))
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 0, y: 5), petRect: rect), "上边界")
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 5, y: 0), petRect: rect), "右边界")
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: -5, y: -5), petRect: rect), "左下角")
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 5, y: 5), petRect: rect), "右上角")
    }

    func test_pointerJustOutsideBoundaryHasDirection() {
        // 边界外一丝即有方向。
        XCTAssertEqual(PetLookOverlay.directionIndex(pointer: CGPoint(x: 0, y: 5.001), petRect: rect), 0)
        XCTAssertEqual(PetLookOverlay.directionIndex(pointer: CGPoint(x: 5.001, y: 0), petRect: rect), 4)
    }

    // MARK: - 负坐标副屏

    func test_negativeCoordinateSecondaryScreen() {
        // 副屏整体位于负坐标区：方向语义与主屏一致（不受平移影响）。
        let secondary = CGRect(x: -1500, y: -500, width: 10, height: 10)
        func secondaryIndex(degrees: CGFloat) -> Int? {
            let radians = degrees * .pi / 180
            let center = CGPoint(x: secondary.midX, y: secondary.midY)
            let pointer = CGPoint(
                x: center.x + radius * sin(radians),
                y: center.y + radius * cos(radians)
            )
            return PetLookOverlay.directionIndex(pointer: pointer, petRect: secondary)
        }
        XCTAssertEqual(secondaryIndex(degrees: 0), 0, "副屏正上")
        XCTAssertEqual(secondaryIndex(degrees: 90), 4, "副屏正右")
        XCTAssertEqual(secondaryIndex(degrees: 180), 8, "副屏正下")
        XCTAssertEqual(secondaryIndex(degrees: 270), 12, "副屏正左")
        XCTAssertNil(
            PetLookOverlay.directionIndex(pointer: CGPoint(x: secondary.midX, y: secondary.midY), petRect: secondary),
            "副屏死区"
        )
    }
}
