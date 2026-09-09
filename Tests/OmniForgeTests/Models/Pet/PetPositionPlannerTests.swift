import XCTest
@testable import OmniForge

/// 位置规划测试：地面贴合、边界夹紧、重力、行走转身、多屏迁移。
final class PetPositionPlannerTests: XCTestCase {
    private let petSize = CGSize(width: 96, height: 96)

    /// 主屏可见区：原点 (0, 25)，尺寸 1440×800（模拟菜单栏 25pt + Dock 后剩余区）。
    private let mainScreen = PetScreenGeometry(
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
        identifier: "display-1"
    )

    /// 副屏可见区：位于主屏右侧。
    private let secondScreen = PetScreenGeometry(
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        identifier: "display-2"
    )

    // MARK: - 地面

    func test_groundYIsVisibleFrameBottom() {
        // 地面仅用于默认落点（重置位置 / 首次出现），不再参与重力掉落。
        XCTAssertEqual(mainScreen.groundY, 25)
    }

    // MARK: - 夹紧

    func test_clampKeepsPetInsideVisibleFrame() {
        let clamped = PetPositionPlanner.clamp(
            CGPoint(x: 5000, y: 5000),
            petSize: petSize,
            to: mainScreen
        )

        XCTAssertEqual(clamped.x, 1440 - 96)
        XCTAssertEqual(clamped.y, 825 - 96)
    }

    func test_clampRaisesBelowGroundPosition() {
        let clamped = PetPositionPlanner.clamp(
            CGPoint(x: 100, y: -200),
            petSize: petSize,
            to: mainScreen
        )

        XCTAssertEqual(clamped.y, 25)
    }

    func test_clampHandlesScreenSmallerThanPet() {
        let tinyScreen = PetScreenGeometry(
            visibleFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
            identifier: "tiny"
        )

        let clamped = PetPositionPlanner.clamp(
            CGPoint(x: 10, y: 10),
            petSize: petSize,
            to: tinyScreen
        )

        // 可见区比宠物小：以左下角为准，避免产生非法区间。
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.y, 0)
    }

    // MARK: - 行走活动范围

    func test_walkRangeIsCentredOnAnchorWithinRadius() {
        let range = PetPositionPlanner.walkRange(
            anchorX: 500,
            radius: 120,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(range.lowerBound, 380)
        XCTAssertEqual(range.upperBound, 620)
    }

    func test_walkRangeClampsToScreenVisibleFrame() {
        // 锚点贴近屏幕左边缘：下界不得超出可见区。
        let range = PetPositionPlanner.walkRange(
            anchorX: 10,
            radius: 120,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(range.lowerBound, mainScreen.visibleFrame.minX)
        XCTAssertEqual(range.upperBound, 130)
    }

    func test_walkRangeClampsToRightEdgeAccountingPetWidth() {
        let rightmost = mainScreen.visibleFrame.maxX - petSize.width
        let range = PetPositionPlanner.walkRange(
            anchorX: rightmost,
            radius: 120,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(range.upperBound, rightmost)
        XCTAssertEqual(range.lowerBound, rightmost - 120)
    }

    func test_walkRangeStaysValidOnNarrowScreen() {
        // 屏幕比宠物还窄：退化为整屏区间，不产生非法 range。
        let narrow = PetScreenGeometry(
            visibleFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
            identifier: "narrow"
        )
        let range = PetPositionPlanner.walkRange(
            anchorX: 20,
            radius: 120,
            petSize: petSize,
            screen: narrow
        )

        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
    }

    // MARK: - 行走步进

    func test_stepWalkMovesRightWithoutTurning() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 500, y: 25),
            direction: .right,
            distance: 20,
            walkRange: 400...600
        )

        XCTAssertEqual(result.position.x, 520)
        XCTAssertEqual(result.direction, .right)
    }

    func test_stepWalkMovesLeftWithoutTurning() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 500, y: 25),
            direction: .left,
            distance: 20,
            walkRange: 400...600
        )

        XCTAssertEqual(result.position.x, 480)
        XCTAssertEqual(result.direction, .left)
    }

    func test_stepWalkTurnsAtRightBoundary() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 600, y: 25),
            direction: .right,
            distance: 30,
            walkRange: 400...600
        )

        XCTAssertEqual(result.direction, .left)
        XCTAssertLessThanOrEqual(result.position.x, 600)
    }

    func test_stepWalkTurnsAtLeftBoundary() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 400, y: 25),
            direction: .left,
            distance: 30,
            walkRange: 400...600
        )

        XCTAssertEqual(result.direction, .right)
        XCTAssertGreaterThanOrEqual(result.position.x, 400)
    }

    func test_stepWalkNeverLeavesWalkRange() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 410, y: 25),
            direction: .left,
            distance: 500,
            walkRange: 400...600
        )

        XCTAssertGreaterThanOrEqual(result.position.x, 400)
        XCTAssertLessThanOrEqual(result.position.x, 600)
    }

    func test_stepWalkPreservesVerticalPosition() {
        // 悬停位置（非地面）行走时高度不变。
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 500, y: 300),
            direction: .right,
            distance: 10,
            walkRange: 400...600
        )

        XCTAssertEqual(result.position.y, 300)
    }

    // MARK: - 多屏

    func test_resolveScreenPrefersRememberedIdentifier() {
        let resolved = PetPositionPlanner.resolveScreen(
            rememberedIdentifier: "display-2",
            screens: [mainScreen, secondScreen],
            mainScreenIdentifier: "display-1"
        )

        XCTAssertEqual(resolved?.identifier, "display-2")
    }

    func test_resolveScreenFallsBackToMainWhenRememberedMissing() {
        let resolved = PetPositionPlanner.resolveScreen(
            rememberedIdentifier: "display-9",
            screens: [mainScreen, secondScreen],
            mainScreenIdentifier: "display-1"
        )

        XCTAssertEqual(resolved?.identifier, "display-1")
    }

    func test_resolveScreenFallsBackToFirstWhenNothingMatches() {
        let resolved = PetPositionPlanner.resolveScreen(
            rememberedIdentifier: nil,
            screens: [mainScreen, secondScreen],
            mainScreenIdentifier: "display-9"
        )

        XCTAssertEqual(resolved?.identifier, "display-1")
    }

    func test_resolveScreenReturnsNilForNoScreens() {
        XCTAssertNil(PetPositionPlanner.resolveScreen(
            rememberedIdentifier: nil,
            screens: [],
            mainScreenIdentifier: nil
        ))
    }

    func test_screenContainingMatchesByPetCenter() {
        // 宠物中心落在副屏内。
        let screen = PetPositionPlanner.screenContaining(
            position: CGPoint(x: 1500, y: 100),
            petSize: petSize,
            screens: [mainScreen, secondScreen]
        )

        XCTAssertEqual(screen?.identifier, "display-2")
    }

    func test_screenContainingPicksNearestWhenOutsideAll() {
        // 宠物在屏幕下方很远处：仍应返回最近的屏幕（主屏）。
        let screen = PetPositionPlanner.screenContaining(
            position: CGPoint(x: 100, y: -5000),
            petSize: petSize,
            screens: [mainScreen, secondScreen]
        )

        XCTAssertEqual(screen?.identifier, "display-1")
    }

    func test_screenContainingReturnsNilForNoScreens() {
        XCTAssertNil(PetPositionPlanner.screenContaining(
            position: .zero,
            petSize: petSize,
            screens: []
        ))
    }
}
