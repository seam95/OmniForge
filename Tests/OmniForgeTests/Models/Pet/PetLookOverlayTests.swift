import XCTest
@testable import OmniForge

/// 看向方向索引纯函数测试：四主方向、16 向中心、半格边界归属、死区与负坐标副屏。
final class PetLookOverlayTests: XCTestCase {
    /// 以 (0, 0) 为中心的 10×10 矩形；指向 (r·sin θ, r·cos θ) 即顺时针 θ 度方向。
    private let rect = CGRect(x: -5, y: -5, width: 10, height: 10)
    private let radius: CGFloat = 100

    /// 顺时针角度 → 期望槽位（正上 0°=0、右 90°=4、下 180°=8、左 270°=12）。
    /// 指针相对**视线枢轴**（眼位）放置：枢轴略高于几何中心，若仍按中心布点，
    /// 边界角会被这 0.5pt 偏移推过取整边界而使半格归属断言失真。
    private func index(degrees: CGFloat) -> Int? {
        let radians = degrees * .pi / 180
        let pivot = PetLookOverlay.pivot(in: rect)
        let pointer = CGPoint(
            x: pivot.x + radius * sin(radians),
            y: pivot.y + radius * cos(radians)
        )
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

    func test_pointerJustOutsideBoundaryIsInsideInnerDeadZone() {
        // 边界外一丝仍在 35pt 内死区内：不产生看向（防窗缘横跳）。
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 0, y: 5.001), petRect: rect), "刚出上边界")
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 5.001, y: 0), petRect: rect), "刚出右边界")
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: -5.001, y: 0), petRect: rect), "刚出左边界")
        XCTAssertNil(PetLookOverlay.directionIndex(pointer: CGPoint(x: 0, y: -5.001), petRect: rect), "刚出下边界")
    }

    func test_pointerBeyondInnerDeadZoneHasDirection() {
        // 越过内死区后按真实方向给出槽位（枢轴略高于几何中心）。
        let pivot = PetLookOverlay.pivot(in: rect)
        XCTAssertEqual(pivot.y, 0.5, accuracy: 1e-9, "枢轴应在高度 55% 处")
        // 正上：指针在枢轴正上方 100pt。
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: CGPoint(x: pivot.x, y: pivot.y + 100), petRect: rect),
            0, "内死区外正上"
        )
        // 正右：指针在枢轴正右方 100pt。
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: CGPoint(x: pivot.x + 100, y: pivot.y), petRect: rect),
            4, "内死区外正右"
        )
    }

    func test_innerDeadZoneBoundaryIsExclusive() {
        let pivot = PetLookOverlay.pivot(in: rect)
        // 距枢轴恰 35pt：不命中（要求 > 35）。取正上方避开矩形死区。
        let atBoundary = CGPoint(x: pivot.x, y: pivot.y + PetLookOverlay.innerDeadZone)
        XCTAssertNil(
            PetLookOverlay.directionIndex(pointer: atBoundary, petRect: rect),
            "距枢轴恰 35pt 不产生看向"
        )
        let justBeyond = CGPoint(x: pivot.x, y: pivot.y + PetLookOverlay.innerDeadZone + 0.001)
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: justBeyond, petRect: rect),
            0, "距枢轴略超 35pt 产生看向"
        )
    }

    func test_outerCutoffStopsFollowing() {
        let pivot = PetLookOverlay.pivot(in: rect)
        // 距枢轴恰 1100pt：不命中（要求 < 1100）。矩形高仅 10pt，远处必在窗外。
        let atCutoff = CGPoint(x: pivot.x + PetLookOverlay.outerCutoff, y: pivot.y)
        XCTAssertNil(
            PetLookOverlay.directionIndex(pointer: atCutoff, petRect: rect),
            "距枢轴恰 1100pt 停止跟随"
        )
        let justInside = CGPoint(x: pivot.x + PetLookOverlay.outerCutoff - 0.001, y: pivot.y)
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: justInside, petRect: rect),
            4, "距枢轴略小于 1100pt 仍跟随"
        )
    }

    func test_customPivotOverridesEyePosition() {
        // 显式传入几何中心作枢轴时，正上方向不受枢轴偏移影响。
        let center = CGPoint(x: rect.midX, y: rect.midY)
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: CGPoint(x: center.x, y: center.y + 100), petRect: rect, pivotOverride: center),
            0
        )
        // 同一指针在默认眼位枢轴下仍是正上（dx 相同、dy 更大，atan2 不变）。
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: CGPoint(x: center.x, y: center.y + 100), petRect: rect),
            0
        )
    }

    func test_eyePivotChangesResultVersusGeometricCenter() {
        // 枢轴偏移必须真实生效：同一指针在几何中心与眼位枢轴下落入不同槽位。
        // 高矩形使 5% 偏移达到 10pt，足以跨过取整边界。
        let tall = CGRect(x: -5, y: -100, width: 10, height: 200)
        let center = CGPoint(x: tall.midX, y: tall.midY)
        // 自中心看恰在 348.8°（槽 15/0 边界之上，归入 0）。
        let pointer = CGPoint(x: center.x - 19.41, y: center.y + 98.08)
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: pointer, petRect: tall, pivotOverride: center),
            0, "以几何中心为枢轴落在槽 0"
        )
        XCTAssertEqual(
            PetLookOverlay.directionIndex(pointer: pointer, petRect: tall),
            15, "以眼位为枢轴同一指针落入槽 15——枢轴偏移真实生效"
        )
    }

    func test_isInsideMatchesRectContainmentIncludingBoundary() {
        // 悬停触发域与看向解耦后，isInside 必须独立保持矩形包含语义。
        XCTAssertTrue(PetLookOverlay.isInside(.zero, petRect: rect), "中心")
        XCTAssertTrue(PetLookOverlay.isInside(CGPoint(x: 4, y: 4), petRect: rect), "内部")
        XCTAssertTrue(PetLookOverlay.isInside(CGPoint(x: 0, y: 5), petRect: rect), "上边界")
        XCTAssertTrue(PetLookOverlay.isInside(CGPoint(x: 5, y: 5), petRect: rect), "右上角")
        XCTAssertFalse(PetLookOverlay.isInside(CGPoint(x: 0, y: 5.001), petRect: rect), "刚出上边界即窗外")
        XCTAssertFalse(PetLookOverlay.isInside(CGPoint(x: -6, y: 0), petRect: rect), "左侧外")
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
