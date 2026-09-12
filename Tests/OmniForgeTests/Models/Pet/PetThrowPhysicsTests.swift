import CoreGraphics
import XCTest
@testable import OmniForge

/// 投掷物理测试：单屏反弹、摩擦与停速、真实 900ms 上限、跨屏通行带与高速路径。
final class PetThrowPhysicsTests: XCTestCase {
    private let petSize = CGSize(width: 96, height: 96)
    /// 主屏：0…1440 × 0…800（visibleFrame 已简化为整屏）。
    private let main = PetScreenGeometry(
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 800),
        identifier: "main"
    )

    private func step(
        position: CGPoint,
        velocity: CGVector,
        elapsed: TimeInterval = 0,
        delta: TimeInterval = 1.0 / 30.0,
        screens: [PetScreenGeometry]
    ) -> PetThrowPhysics.StepResult {
        PetThrowPhysics.step(
            position: position, velocity: velocity, elapsed: elapsed,
            delta: delta, petSize: petSize, screens: screens
        )
    }

    // MARK: - 单屏边界

    func test_freeFlightWithinScreenDoesNotBounce() {
        let result = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 100, dy: 60),
            screens: [main]
        )
        // dt = 1/30 被 clamp 到 32ms：位移 (3.2, 1.92)。无碰撞，速度只受摩擦。
        XCTAssertEqual(result.position.x, 500 + 100.0 * 0.032, accuracy: 0.001)
        XCTAssertEqual(result.position.y, 400 + 60.0 * 0.032, accuracy: 0.001)
        XCTAssertFalse(result.finished)
    }

    func test_bounceAtRightEdgeLosesThirtyPercentAndDropsRemainder() {
        // 一步大幅越界右缘（剩余位移丢弃、法向速度 ×-0.7）。
        let result = step(
            position: CGPoint(x: 1300, y: 400),
            velocity: CGVector(dx: 5000, dy: 0),
            screens: [main]
        )
        let maxX = main.visibleFrame.maxX - petSize.width  // 1344
        XCTAssertEqual(result.position.x, maxX, accuracy: 0.001, "停在接触处")
        // 该步剩余位移丢弃；速度 = 5000 × (-0.7) × 摩擦（dt 按 clamp 后的 32ms）。
        let damping = CGFloat(pow(0.88, 0.032 / 0.016))
        XCTAssertEqual(result.velocity.dx, 5000 * -0.7 * damping, accuracy: 0.5)
        XCTAssertEqual(result.velocity.dy, 0)
    }

    func test_bounceAtFloorAndCeiling() {
        let floor = step(
            position: CGPoint(x: 500, y: 10),
            velocity: CGVector(dx: 0, dy: -2000),
            screens: [main]
        )
        XCTAssertEqual(floor.position.y, main.visibleFrame.minY, accuracy: 0.001, "地面反弹停在底边")
        XCTAssertGreaterThan(floor.velocity.dy, 0, "法向速度 ×-0.7 后翻正（向下撞地弹起向上）")
        let ceiling = step(
            position: CGPoint(x: 500, y: 690),
            velocity: CGVector(dx: 0, dy: 2000),
            screens: [main]
        )
        XCTAssertEqual(ceiling.position.y, main.visibleFrame.maxY - petSize.height, accuracy: 0.001)
        XCTAssertLessThan(ceiling.velocity.dy, 0, "顶棚反弹后法向速度翻负")
    }

    func test_cornerBouncesBothAxes() {
        let result = step(
            position: CGPoint(x: 1340, y: 690),
            velocity: CGVector(dx: 3000, dy: 3000),
            screens: [main]
        )
        XCTAssertEqual(result.position.x, main.visibleFrame.maxX - petSize.width, accuracy: 0.001)
        XCTAssertEqual(result.position.y, main.visibleFrame.maxY - petSize.height, accuracy: 0.001)
        XCTAssertLessThan(result.velocity.dx, 0)
        XCTAssertLessThan(result.velocity.dy, 0)
    }

    // MARK: - 摩擦与停止

    func test_dampingFactorPerSixteenMilliseconds() {
        let result = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 1000, dy: 0),
            delta: 0.016,  // 恰一帧 16ms
            screens: [main]
        )
        XCTAssertEqual(Double(result.velocity.dx), 1000 * 0.88, accuracy: 0.5)
    }

    func test_stopSpeedThresholdFinishes() {
        // 速度 64 < 65：本步积分后即结束。
        let result = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 64, dy: 0),
            screens: [main]
        )
        XCTAssertTrue(result.finished)
        // 速度 200：一步摩擦后仍高于阈值 → 未结束。
        let alive = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 200, dy: 0),
            screens: [main]
        )
        XCTAssertFalse(alive.finished)
    }

    func test_realElapsedOverMaxDurationFinishesWithoutMoving() {
        // 真实历时 0.9s（含系统暂停的空转）：第一 tick 超时先结束，不再移动一步。
        let result = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 2000, dy: 0),
            elapsed: 0.9,
            delta: 1.0 / 30.0,
            screens: [main]
        )
        XCTAssertEqual(result.position.x, 500, "超时先结束，不移动")
        XCTAssertTrue(result.finished)
    }

    func test_negativeOrHugeDeltaIsClamped() {
        // 负 delta：位移钳到 0，不倒退。
        let negative = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 1000, dy: 0),
            delta: -5,
            screens: [main]
        )
        XCTAssertEqual(negative.position.x, 500, accuracy: 0.001)
        // 巨大 delta：位移钳到 32ms，不瞬移。
        let huge = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 1000, dy: 0),
            delta: 10,
            screens: [main]
        )
        XCTAssertEqual(huge.position.x, 500 + 1000 * 0.032, accuracy: 0.001)
    }

    func test_emptyScreensCancelsMotionSafely() {
        let result = step(
            position: CGPoint(x: 500, y: 400),
            velocity: CGVector(dx: 2000, dy: 0),
            screens: []
        )
        XCTAssertTrue(result.finished, "无可用屏幕取消运动")
        XCTAssertEqual(result.position, CGPoint(x: 500, y: 400), "保留安全状态")
    }

    // MARK: - 跨屏

    /// 右侧相邻副屏（共享边无缝）：1440…2880 × 0…800。
    private var rightNeighbor: PetScreenGeometry {
        PetScreenGeometry(
            visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 800),
            identifier: "right"
        )
    }

    func test_crossesSeamlessSharedEdge() {
        // 主屏右缘以较高初速向右：摩擦几何级数和足以越过共享边。
        var position = CGPoint(x: 1300, y: 400)
        var velocity = CGVector(dx: 800, dy: 0)
        var crossed = false
        for _ in 0..<40 {
            let result = step(position: position, velocity: velocity, screens: [main, rightNeighbor])
            position = result.position
            velocity = result.velocity
            if result.finished { break }
            if position.x > 1440 - petSize.width { crossed = true }
        }
        XCTAssertTrue(crossed, "共享边足够容纳宠物时应可跨屏")
    }

    func test_staggeredScreensWithInsufficientOpeningBlocksCrossing() {
        // 副屏垂直错位：与主屏 y 重叠只有 0…100，宠物高 96 > 100-0=100——恰好 100 ≥ 96 能过。
        // 构造更紧的：重叠 0…50，宠物高 96 放不进去 → 不可穿过。
        let staggered = PetScreenGeometry(
            visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 50),
            identifier: "staggered"
        )
        let result = step(
            position: CGPoint(x: 1300, y: 10),
            velocity: CGVector(dx: 2000, dy: 0),
            screens: [main, staggered]
        )
        // 宠物 y 0…96，副屏只覆盖 0…50：横截面不被副屏完全覆盖 → 主屏右缘反弹。
        XCTAssertEqual(result.position.x, main.visibleFrame.maxX - petSize.width, accuracy: 0.001,
                       "开口不足的错位屏不可穿过")
        XCTAssertLessThan(result.velocity.dx, 0)
    }

    func test_gapBetweenScreensBlocksCrossing() {
        // 屏间空隙 50pt：不可跨越（高速一步也不穿越）。
        let gapped = PetScreenGeometry(
            visibleFrame: CGRect(x: 1490, y: 0, width: 1440, height: 800),
            identifier: "gapped"
        )
        let result = step(
            position: CGPoint(x: 1300, y: 400),
            velocity: CGVector(dx: 20000, dy: 0),
            screens: [main, gapped]
        )
        XCTAssertEqual(result.position.x, main.visibleFrame.maxX - petSize.width, accuracy: 0.001,
                       "屏间空隙不可跨越，高速不穿越外缘")
    }

    func test_verticalNeighborScreensShareVerticalBand() {
        // 上方相邻副屏（共享水平边）：x 0…1440 × 800…1600。
        let above = PetScreenGeometry(
            visibleFrame: CGRect(x: 0, y: 800, width: 1440, height: 800),
            identifier: "above"
        )
        var position = CGPoint(x: 500, y: 700)
        var velocity = CGVector(dx: 0, dy: 400)
        var crossed = false
        for _ in 0..<40 {
            let result = step(position: position, velocity: velocity, screens: [main, above])
            position = result.position
            velocity = result.velocity
            if result.finished { break }
            if position.y > 800 - petSize.height { crossed = true }
        }
        XCTAssertTrue(crossed, "上下相邻屏共享边可垂直穿过")
    }

    func test_petOnSecondaryScreenBouncesItsOwnEdges() {
        // 宠物已在副屏：副屏自己的外缘反弹（并集边界），不回吸主屏。
        let result = step(
            position: CGPoint(x: 2700, y: 400),
            velocity: CGVector(dx: 3000, dy: 0),
            screens: [main, rightNeighbor]
        )
        XCTAssertEqual(result.position.x, rightNeighbor.visibleFrame.maxX - petSize.width, accuracy: 0.001)
    }
}
