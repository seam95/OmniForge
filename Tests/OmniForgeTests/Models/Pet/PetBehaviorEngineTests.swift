import XCTest
@testable import OmniForge

/// 行为状态机测试：状态转移、加权决策、抚摸恢复、二期事件入口形状。
@MainActor
final class PetBehaviorEngineTests: XCTestCase {
    /// 构造固定随机序列的引擎（0.1 = 走 idle 分支，0.9 = 走 walk 分支）。
    private func makeEngine(rolls: [Double]) -> PetBehaviorEngine {
        PetBehaviorEngine(
            randomSource: SeededPetRandomSource(values: rolls),
            idleWeight: 0.6,
            idleDurationRange: 2...2,
            walkDurationRange: 3...3,
            walkSpeed: 40
        )
    }

    // MARK: - 初始状态与决策

    func test_initialStateIsIdle() {
        let engine = makeEngine(rolls: [0.1])

        XCTAssertEqual(engine.state, .idle)
    }

    func test_decisionBelowIdleWeightStaysIdle() {
        let engine = makeEngine(rolls: [0.1])

        let decision = engine.nextIdleDecision()

        XCTAssertEqual(decision.state, .idle)
        XCTAssertEqual(decision.duration, 2, accuracy: 0.0001)
    }

    func test_decisionAboveIdleWeightStartsWalk() {
        // 第一次 roll 0.9 → walk；第二次 roll 0.9 → 朝右；第三次 roll 给时长。
        let engine = makeEngine(rolls: [0.9, 0.9, 0.0])

        let decision = engine.nextIdleDecision()

        XCTAssertEqual(decision.state, .walk(direction: .right))
        XCTAssertEqual(decision.duration, 3, accuracy: 0.0001)
    }

    func test_walkDirectionFollowsSecondRoll() {
        let engine = makeEngine(rolls: [0.9, 0.1, 0.0])

        let decision = engine.nextIdleDecision()

        XCTAssertEqual(decision.state, .walk(direction: .left))
    }

    func test_walkDeltaUsesSpeedAndDirectionSign() {
        let engine = makeEngine(rolls: [0.9, 0.9, 0.0])
        engine.apply(engine.nextIdleDecision())

        // 40 点/秒 × 0.5 秒 = 20 点，朝右为正。
        XCTAssertEqual(engine.walkDelta(dt: 0.5), 20, accuracy: 0.0001)
    }

    func test_walkDeltaIsZeroWhenNotWalking() {
        let engine = makeEngine(rolls: [0.1])

        XCTAssertEqual(engine.walkDelta(dt: 1.0), 0)
    }

    // MARK: - 拖拽与掉落

    func test_beginDragEntersDragFromAnyState() {
        let engine = makeEngine(rolls: [0.9, 0.9, 0.0])
        engine.apply(engine.nextIdleDecision())

        engine.beginDrag()

        XCTAssertEqual(engine.state, .drag)
    }

    func test_endDragHoversAtDropPointAndReturnsToIdle() {
        // 拖拽松手后宠物悬停在松手处（无重力掉落），直接回 idle。
        let engine = makeEngine(rolls: [0.1])
        engine.beginDrag()

        engine.endDrag()

        XCTAssertEqual(engine.state, .idle)
    }

    func test_endDragFromWalkReturnsToIdle() {
        let engine = makeEngine(rolls: [0.9, 0.9, 0.0])
        engine.apply(engine.nextIdleDecision())
        engine.beginDrag()

        engine.endDrag()

        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - 抚摸

    func test_petFromIdleResumesToIdle() {
        let engine = makeEngine(rolls: [0.1])

        engine.pet()
        XCTAssertEqual(engine.state, .petted(resumeState: .idle))

        engine.finishPetted()
        XCTAssertEqual(engine.state, .idle)
    }

    func test_petFromWalkResumesWalkWithSameDirection() {
        let engine = makeEngine(rolls: [0.9, 0.1, 0.0])
        engine.apply(engine.nextIdleDecision())
        XCTAssertEqual(engine.state, .walk(direction: .left))

        engine.pet()
        engine.finishPetted()

        XCTAssertEqual(engine.state, .walk(direction: .left))
    }

    func test_petIsNotReentrant() {
        let engine = makeEngine(rolls: [0.1])

        engine.pet()
        engine.pet()

        XCTAssertEqual(engine.state, .petted(resumeState: .idle))
    }

    func test_finishPettedOutsidePettedStateIsNoop() {
        let engine = makeEngine(rolls: [0.1])

        engine.finishPetted()

        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - 外部事件入口（形状锁定）

    func test_submitEventEnqueuesWithoutChangingBehavior() {
        let engine = makeEngine(rolls: [0.1])

        engine.submit(.activityStarted(kind: .thinking))
        engine.submit(.celebrationTriggered)

        XCTAssertEqual(engine.pendingExternalEvents.count, 2)
        // 一期：事件不影响行为状态。
        XCTAssertEqual(engine.state, .idle)
    }

    func test_drainExternalEventsClearsQueue() {
        let engine = makeEngine(rolls: [0.1])
        engine.submit(.attentionRequested)

        engine.drainExternalEvents()

        XCTAssertTrue(engine.pendingExternalEvents.isEmpty)
    }

    func test_resetToIdleOverridesAnyState() {
        let engine = makeEngine(rolls: [0.9, 0.9, 0.0])
        engine.apply(engine.nextIdleDecision())

        engine.resetToIdle()

        XCTAssertEqual(engine.state, .idle)
    }
}
