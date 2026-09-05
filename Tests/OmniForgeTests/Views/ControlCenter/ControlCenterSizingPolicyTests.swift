import XCTest
@testable import OmniForge

/// 尺寸契约纯计算（SPEC §3.1 / 验收 A1 的逻辑侧）：
/// 空态下限、屏幕上限、580 上限、物理像素对齐与无效测量拒绝。
final class ControlCenterSizingPolicyTests: XCTestCase {
    private func input(
        natural: CGFloat,
        chrome: CGFloat = 110,
        available: CGFloat = 1055,
        isEmpty: Bool = false,
        scale: CGFloat = 2
    ) -> ControlCenterSizingInput {
        ControlCenterSizingInput(
            width: 380,
            naturalContentHeight: natural,
            chromeHeight: chrome,
            availableTotalHeight: available,
            isEmptyState: isEmpty,
            backingScale: scale
        )
    }

    func test_shortContent_shrinksToNaturalHeight() {
        // A1：短内容最终高度 = 自然高度（120/320pt 合成内容）。
        for natural in [CGFloat(120), 320] {
            let target = ControlCenterSizingPolicy.resolve(input(natural: natural))
            XCTAssertNotNil(target)
            XCTAssertEqual(target?.viewportHeight ?? 0, natural, accuracy: 0.51)
            XCTAssertEqual(target?.totalHeight ?? 0, 110 + natural, accuracy: 0.51)
        }
    }

    func test_longContent_capsAtViewportMax() {
        // A1：长内容（900pt）不超过 580 上限。
        let target = ControlCenterSizingPolicy.resolve(input(natural: 900))
        XCTAssertEqual(target?.viewportHeight, 580)
        XCTAssertEqual(target?.totalHeight, 690)
    }

    func test_emptyState_appliesFloorUnlessCappedByScreen() {
        let withFloor = ControlCenterSizingPolicy.resolve(input(natural: 40, isEmpty: true))
        XCTAssertEqual(withFloor?.viewportHeight, 120)

        // 极小可用空间下屏幕上限优先（SPEC §3.1）。
        let tinyScreen = ControlCenterSizingPolicy.resolve(
            input(natural: 40, chrome: 110, available: 150, isEmpty: true)
        )
        XCTAssertEqual(tinyScreen?.viewportHeight, 40, "150 - 110 = 40 上限优先于 120 下限")
    }

    func test_screenCap_limitsViewport() {
        let target = ControlCenterSizingPolicy.resolve(
            input(natural: 900, chrome: 110, available: 500)
        )
        XCTAssertEqual(target?.viewportHeight, 390, "500 - 110 = 390")
    }

    func test_screenTooSmallForChrome_degeneratesSafely() {
        // 连 chrome 都容纳不下：viewport 0、total = chrome，不允许负值（SPEC §3.1）。
        let target = ControlCenterSizingPolicy.resolve(
            input(natural: 580, chrome: 110, available: 80)
        )
        XCTAssertEqual(target?.viewportHeight, 0)
        XCTAssertGreaterThanOrEqual(target!.totalHeight, 0)
    }

    func test_invalidMeasurements_areRejected() {
        for bad in [CGFloat(0), -10, .nan, .infinity, -.infinity] {
            XCTAssertNil(ControlCenterSizingPolicy.resolve(input(natural: bad)))
        }
        XCTAssertNil(ControlCenterSizingPolicy.resolve(input(natural: 300, chrome: .nan)))
        XCTAssertNil(ControlCenterSizingPolicy.resolve(input(natural: 300, available: 0)))
        XCTAssertNil(ControlCenterSizingPolicy.resolve(input(natural: 300, scale: 0)))
    }

    func test_pixelAlignment_floorsAndDetectsEquality() {
        XCTAssertEqual(ControlCenterSizingPolicy.pixelAligned(586.7, scale: 2), 586.5)
        XCTAssertEqual(ControlCenterSizingPolicy.pixelAligned(586.2, scale: 2), 586)
        // ≤1 物理像素差异不重复提交。
        XCTAssertTrue(ControlCenterSizingPolicy.isEffectivelyEqual(586.0, 586.4, scale: 2))
        XCTAssertTrue(ControlCenterSizingPolicy.isEffectivelyEqual(586.0, 586.5, scale: 2))
        XCTAssertFalse(ControlCenterSizingPolicy.isEffectivelyEqual(586.0, 586.6, scale: 2))
        XCTAssertFalse(ControlCenterSizingPolicy.isEffectivelyEqual(586.0, 590, scale: 2))
    }

    func test_pixelAlignedTotal_neverExceedsRawHeight() {
        let target = ControlCenterSizingPolicy.resolve(
            input(natural: 469.9, chrome: 110.3, available: 600, scale: 3)
        )
        XCTAssertLessThanOrEqual(target!.totalHeight, 600)
        XCTAssertGreaterThanOrEqual(target!.viewportHeight, 0)
    }

    func test_policyConstants_matchShellContract() {
        XCTAssertEqual(ControlCenterSizingPolicy.maxViewportHeight, ControlCenterContentMetrics.viewportHeight)
        XCTAssertEqual(ControlCenterSizingPolicy.emptyFloorHeight, ControlCenterContentMetrics.emptyContentMinHeight)
    }
}
