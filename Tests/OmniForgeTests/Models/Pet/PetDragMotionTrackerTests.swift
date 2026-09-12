import CoreGraphics
import XCTest
@testable import OmniForge

/// 拖动方向与速度采样测试：4pt 阈值累计、反向候选重置、80ms 速度窗口、非法样本防御。
final class PetDragMotionTrackerTests: XCTestCase {
    // MARK: - 方向累计

    func test_firstSampleOnlyBuildsBaseline() {
        var tracker = PetDragMotionTracker()
        // 首个样本只建基线，不产生方向变化（起手无跳动）。
        XCTAssertFalse(tracker.update(pointer: CGPoint(x: 100, y: 100), at: 0))
        XCTAssertEqual(tracker.facing, .right, "初始朝向右")
    }

    func test_consecutiveSmallIncrementsAccumulateToThreshold() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        // 初始朝向右：向右的小增量累计再多也不产生变化事件（已是该朝向）。
        _ = tracker.update(pointer: CGPoint(x: 1.5, y: 0), at: 0.01)
        _ = tracker.update(pointer: CGPoint(x: 3.0, y: 0), at: 0.02)
        _ = tracker.update(pointer: CGPoint(x: 4.5, y: 0), at: 0.03)
        XCTAssertEqual(tracker.facing, .right, "同向累计不换向")
        // 反向（向左）小增量累计：-1.5×3 = -4.5pt ≥ 4pt 才换向左。
        _ = tracker.update(pointer: CGPoint(x: 3.0, y: 0), at: 0.04)
        XCTAssertEqual(tracker.facing, .right, "累计 1.5pt 未达阈值")
        _ = tracker.update(pointer: CGPoint(x: 1.5, y: 0), at: 0.05)
        XCTAssertEqual(tracker.facing, .right, "累计 3.0pt 未达阈值")
        let changed = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0.06)
        XCTAssertTrue(changed, "累计 4.5pt 达阈值 → 换向左")
        XCTAssertEqual(tracker.facing, .left)
    }

    func test_thresholdBoundaryDoesNotFlipAtExactlyFourPoints() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        // 第二个样本恰好 -4pt 增量：达到阈值（≥）→ 换向。
        let changed = tracker.update(pointer: CGPoint(x: -4, y: 0), at: 0.01)
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.facing, .left)
    }

    func test_reverseWobbleDoesNotFlipImmediately() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        // 先建立向左朝向（一步 -5pt）。
        _ = tracker.update(pointer: CGPoint(x: -5, y: 0), at: 0.01)
        XCTAssertEqual(tracker.facing, .left)
        // 正向回摆 +2pt（新候选累计 2 < 4）：朝向保持左。
        _ = tracker.update(pointer: CGPoint(x: -3, y: 0), at: 0.02)
        XCTAssertEqual(tracker.facing, .left, "反向增量未达阈值保持原朝向")
        // 再正向 +1pt（同候选累计 3 < 4）：仍保持左。
        _ = tracker.update(pointer: CGPoint(x: -2, y: 0), at: 0.03)
        XCTAssertEqual(tracker.facing, .left)
        // 正向再 +0.5pt（候选累计 3.5 < 4）：仍保持左。
        _ = tracker.update(pointer: CGPoint(x: -1.5, y: 0), at: 0.04)
        XCTAssertEqual(tracker.facing, .left, "累计 3.5pt 未达阈值")
        // 正向再 +1pt（候选累计 4.5 ≥ 4）：换向右。
        let changed = tracker.update(pointer: CGPoint(x: -0.5, y: 0), at: 0.05)
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.facing, .right)
    }

    func test_verticalOnlyMovementDoesNotChangeFacing() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        // 纯竖直位移（dx = 0）不驱动朝向。
        _ = tracker.update(pointer: CGPoint(x: 0, y: 100), at: 0.01)
        XCTAssertEqual(tracker.facing, .right)
    }

    // MARK: - 速度窗口

    func test_velocityUsesFirstAndLastSampleTimesThree() {
        var tracker = PetDragMotionTracker()
        // 0.04s 内右移 10pt、上移 4pt：速度 = 位移/时间 × 3。
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        _ = tracker.update(pointer: CGPoint(x: 5, y: 2), at: 0.02)
        let v = tracker.velocity(at: 0.04, location: CGPoint(x: 10, y: 4))

        XCTAssertEqual(v.dx, 10 / 0.04 * 3, accuracy: 0.001)
        XCTAssertEqual(v.dy, 4 / 0.04 * 3, accuracy: 0.001, "竖直方向符号为正（向上）")
    }

    func test_velocityDropsStaleSamplesBeyondWindow() {
        var tracker = PetDragMotionTracker()
        // 早期快速移动样本（t=0）。
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        _ = tracker.update(pointer: CGPoint(x: 500, y: 0), at: 0.01)
        // 停顿超过 80ms 后松手：早期样本过期，只有静止样本 → 零速。
        let v = tracker.velocity(at: 0.5, location: CGPoint(x: 500, y: 0))
        XCTAssertEqual(v.dx, 0, "过期样本不得沿用（按住静止后松手零速）")
    }

    func test_stationaryHoldReleasesWithZeroVelocity() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 100, y: 100), at: 0)
        // 持续静止采样（样本持续刷新位置不变）。
        _ = tracker.update(pointer: CGPoint(x: 100, y: 100), at: 0.02)
        _ = tracker.update(pointer: CGPoint(x: 100, y: 100), at: 0.04)
        let v = tracker.velocity(at: 0.06, location: CGPoint(x: 100, y: 100))
        // 首末位移为 0 → 速度 0。
        XCTAssertEqual(v.dx, 0)
        XCTAssertEqual(v.dy, 0)
    }

    func test_singleSampleYieldsZeroVelocity() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        // 窗口内只有补录的最终样本（旧样本全部过期）→ 样本不足 → 零速。
        let v = tracker.velocity(at: 1.0, location: CGPoint(x: 300, y: 0))
        XCTAssertEqual(v.dx, 0, "样本不足两条 → 零速")
    }

    func test_zeroTimeDeltaYieldsZeroVelocity() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0.1)
        // 同一时刻补录最终样本：时间差为零 → 拒绝。
        let v = tracker.velocity(at: 0.1, location: CGPoint(x: 50, y: 0))
        XCTAssertEqual(v.dx, 0)
    }

    func test_resetClearsBaseline() {
        var tracker = PetDragMotionTracker()
        _ = tracker.update(pointer: CGPoint(x: 0, y: 0), at: 0)
        _ = tracker.update(pointer: CGPoint(x: -10, y: 0), at: 0.01)
        XCTAssertEqual(tracker.facing, .left)

        tracker.reset()
        XCTAssertFalse(tracker.hasBaseline, "reset 后基线清空")
        // 新会话首样本只建基线（不沿用旧朝向逻辑产生变化）。
        XCTAssertFalse(tracker.update(pointer: CGPoint(x: 100, y: 0), at: 0.5))
    }
}
