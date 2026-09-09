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
        XCTAssertEqual(mainScreen.groundY, 25)
    }

    func test_snapToGroundKeepsXAndSetsGroundY() {
        let position = CGPoint(x: 300, y: 500)

        let snapped = PetPositionPlanner.snapToGround(position, to: mainScreen)

        XCTAssertEqual(snapped.x, 300)
        XCTAssertEqual(snapped.y, 25)
    }

    func test_isOnGroundDetectsExactGround() {
        XCTAssertTrue(PetPositionPlanner.isOnGround(CGPoint(x: 100, y: 25), to: mainScreen))
        XCTAssertFalse(PetPositionPlanner.isOnGround(CGPoint(x: 100, y: 26), to: mainScreen))
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

    // MARK: - 重力

    func test_gravityAcceleratesDownward() {
        let result = PetPositionPlanner.applyGravity(
            position: CGPoint(x: 100, y: 500),
            velocity: 0,
            dt: 0.1,
            acceleration: -1000,
            screen: mainScreen
        )

        XCTAssertLessThan(result.position.y, 500)
        XCTAssertLessThan(result.velocity, 0)
        XCTAssertFalse(result.landed)
    }

    func test_gravityLandsOnGroundAndResetsVelocity() {
        let result = PetPositionPlanner.applyGravity(
            position: CGPoint(x: 100, y: 30),
            velocity: -500,
            dt: 0.5,
            acceleration: -1000,
            screen: mainScreen
        )

        XCTAssertEqual(result.position.y, 25)
        XCTAssertEqual(result.velocity, 0)
        XCTAssertTrue(result.landed)
    }

    // MARK: - 行走

    func test_stepWalkMovesRightWithoutTurning() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 500, y: 25),
            direction: .right,
            distance: 20,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(result.position.x, 520)
        XCTAssertEqual(result.direction, .right)
    }

    func test_stepWalkMovesLeftWithoutTurning() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 500, y: 25),
            direction: .left,
            distance: 20,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(result.position.x, 480)
        XCTAssertEqual(result.direction, .left)
    }

    func test_stepWalkTurnsAtRightEdge() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 1440 - 96, y: 25),
            direction: .right,
            distance: 30,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(result.direction, .left)
        XCTAssertLessThanOrEqual(result.position.x, 1440 - 96)
    }

    func test_stepWalkTurnsAtLeftEdge() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 0, y: 25),
            direction: .left,
            distance: 30,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertEqual(result.direction, .right)
        XCTAssertGreaterThanOrEqual(result.position.x, 0)
    }

    func test_stepWalkNeverLeavesVisibleFrame() {
        let result = PetPositionPlanner.stepWalk(
            position: CGPoint(x: 10, y: 25),
            direction: .left,
            distance: 500,
            petSize: petSize,
            screen: mainScreen
        )

        XCTAssertGreaterThanOrEqual(result.position.x, mainScreen.visibleFrame.minX)
        XCTAssertLessThanOrEqual(result.position.x, mainScreen.visibleFrame.maxX - petSize.width)
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
