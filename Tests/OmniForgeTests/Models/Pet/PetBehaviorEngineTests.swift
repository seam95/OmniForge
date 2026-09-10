import XCTest
@testable import OmniForge

/// 行为状态机测试：转移矩阵、好动度缩放、稳态时长占比、交互态回落。
@MainActor
final class PetBehaviorEngineTests: XCTestCase {
    /// 固定随机序列构造引擎。
    private func makeEngine(rolls: [Double], tuning: PetBehaviorTuning = .default) -> PetBehaviorEngine {
        PetBehaviorEngine(
            randomSource: SeededPetRandomSource(values: rolls),
            tuning: tuning
        )
    }

    // MARK: - 转移矩阵

    func test_transitionWeightsRowsSumToOne() {
        let tuning = PetBehaviorTuning.default

        for kind in PetAutonomyKind.allCases {
            let row = tuning.transitionWeights(from: kind)
            let total = row.values.reduce(0, +)
            XCTAssertEqual(total, 1.0, accuracy: 0.0001, "\(kind) 行权重和应为 1")
            for target in PetAutonomyKind.allCases {
                XCTAssertGreaterThanOrEqual(row[target] ?? 0, 0)
            }
        }
    }

    func test_idleRowPrefersStayingIdle() {
        let tuning = PetBehaviorTuning.default
        let row = tuning.transitionWeights(from: .idle)

        XCTAssertGreaterThan(row[.idle] ?? 0, row[.walkLeft] ?? 0)
        XCTAssertGreaterThan(row[.idle] ?? 0, row[.walkRight] ?? 0)
    }

    func test_walkRowsPreferReturningToIdle() {
        let tuning = PetBehaviorTuning.default
        let row = tuning.transitionWeights(from: .walkLeft)

        XCTAssertGreaterThan(row[.idle] ?? 0, row[.walkLeft] ?? 0)
        XCTAssertGreaterThan(row[.idle] ?? 0, row[.walkRight] ?? 0)
    }

    func test_activityLevelScalesIdleSelfWeight() {
        var quiet = PetBehaviorTuning.default
        quiet.activityLevel = 0
        var lively = PetBehaviorTuning.default
        lively.activityLevel = 1

        let quietIdleWeight = quiet.transitionWeights(from: .idle)[.idle] ?? 0
        let baseIdleWeight = PetBehaviorTuning.default.transitionWeights(from: .idle)[.idle] ?? 0
        let livelyIdleWeight = lively.transitionWeights(from: .idle)[.idle] ?? 0

        // 安静档 idle 自环占比更高、活泼档更低。
        XCTAssertGreaterThan(quietIdleWeight, baseIdleWeight)
        XCTAssertGreaterThan(baseIdleWeight, livelyIdleWeight)
    }

    func test_activityPresetsCoverSensibleRange() {
        XCTAssertEqual(PetBehaviorTuning.ActivityPreset.balanced.activityLevel, 0.5)
        XCTAssertLessThan(
            PetBehaviorTuning.ActivityPreset.quiet.activityLevel,
            PetBehaviorTuning.ActivityPreset.lively.activityLevel
        )
    }

    // MARK: - 决策

    func test_initialStateIsIdle() {
        let engine = makeEngine(rolls: [0.1])

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.autonomy, .idle)
    }

    func test_decisionFromIdleWithLowRollStaysIdle() {
        // 基准档 idle 自环占比 ~0.65：roll 0.1 落在 idle；时长 roll 0 → 下界 2s。
        let engine = makeEngine(rolls: [0.1, 0.0])

        let decision = engine.nextAutonomousDecision()

        XCTAssertEqual(decision.state, .idle)
        XCTAssertEqual(decision.duration, 2, accuracy: 0.0001)
        XCTAssertEqual(engine.autonomy, .idle)
    }

    func test_decisionFromIdleWithHighRollEntersWalk() {
        // roll 0.9：先减 idle 0.65 再减 walkLeft 0.175 后仍 ≥0，落在 walkRight；
        // 第二个 roll（0.0）决定时长（下界 1s）。
        let engine = makeEngine(rolls: [0.9, 0.0])

        let decision = engine.nextAutonomousDecision()

        XCTAssertEqual(decision.state, .walk(direction: .right))
        XCTAssertEqual(engine.autonomy, .walkRight)
        XCTAssertEqual(decision.duration, 1, accuracy: 0.0001)
    }

    func test_walkDeltaUsesSpeedAndDirectionSign() {
        let engine = makeEngine(rolls: [0.9, 0.0])
        let decision = engine.nextAutonomousDecision()
        engine.apply(decision)

        // 30 点/秒 × 0.5 秒 = 15 点，朝右为正。
        XCTAssertEqual(engine.walkDelta(dt: 0.5), 15, accuracy: 0.0001)
    }

    func test_walkDeltaIsZeroWhenNotWalking() {
        let engine = makeEngine(rolls: [0.1])

        XCTAssertEqual(engine.walkDelta(dt: 1.0), 0)
    }

    // MARK: - 稳态时长占比（矩阵设计的核心约束）

    /// 大步数模拟决策序列，统计 idle 时长占比。
    private func idleDutyCycle(tuning: PetBehaviorTuning, steps: Int = 30_000) -> Double {
        let engine = PetBehaviorEngine(randomSource: SystemPetRandomSource(), tuning: tuning)
        var idleSeconds = 0.0
        var totalSeconds = 0.0
        for _ in 0..<steps {
            let decision = engine.nextAutonomousDecision()
            totalSeconds += decision.duration
            if case .idle = decision.state { idleSeconds += decision.duration }
        }
        return idleSeconds / max(totalSeconds, 1)
    }

    func test_balancedPresetKeepsIdleDutyCycleAbove70Percent() {
        let duty = idleDutyCycle(tuning: .default)

        // 理论值 ~82%，断言下界留随机波动余量。
        XCTAssertGreaterThanOrEqual(duty, 0.70, "适中档 idle 时长占比应 ≥70%，实际 \(duty)")
    }

    func test_quietPresetIsQuieterThanLively() {
        var quiet = PetBehaviorTuning.default
        quiet.activityLevel = 0.2
        var lively = PetBehaviorTuning.default
        lively.activityLevel = 0.85

        XCTAssertGreaterThan(
            idleDutyCycle(tuning: quiet, steps: 20_000),
            idleDutyCycle(tuning: lively, steps: 20_000)
        )
    }

    // MARK: - 交互态

    func test_beginDragEntersDragFromAnyState() {
        let engine = makeEngine(rolls: [0.9, 0.0])
        engine.apply(engine.nextAutonomousDecision())

        engine.beginDrag()

        XCTAssertEqual(engine.state, .drag)
    }

    func test_endDragHoversAtDropPointAndReturnsToIdle() {
        // 拖拽松手后宠物悬停在松手处（无重力掉落），直接回 idle。
        let engine = makeEngine(rolls: [0.1])
        engine.beginDrag()

        engine.endDrag()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.autonomy, .idle)
    }

    func test_petFromWalkResumesWalkWithSameDirection() {
        let engine = makeEngine(rolls: [0.9, 0.0])
        engine.apply(engine.nextAutonomousDecision())
        XCTAssertEqual(engine.state, .walk(direction: .right))

        engine.pet()
        engine.finishPetted()

        XCTAssertEqual(engine.state, .walk(direction: .right))
        XCTAssertEqual(engine.autonomy, .walkRight)
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

    func test_submitUnmappedEventsEnqueueWithoutChangingBehavior() {
        let engine = makeEngine(rolls: [0.1])

        engine.submit(.activityStarted(kind: .thinking))
        engine.submit(.activityEnded(kind: .working))

        XCTAssertEqual(engine.pendingExternalEvents.count, 2)
        XCTAssertEqual(engine.state, .idle)
    }

    func test_drainExternalEventsClearsQueue() {
        let engine = makeEngine(rolls: [0.1])
        engine.submit(.attentionRequested)

        engine.drainExternalEvents()

        XCTAssertTrue(engine.pendingExternalEvents.isEmpty)
    }

    func test_resetToIdleOverridesAnyState() {
        let engine = makeEngine(rolls: [0.9, 0.0])
        engine.apply(engine.nextAutonomousDecision())

        engine.resetToIdle()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.autonomy, .idle)
    }

    // MARK: - 反应（二期事件分发）

    func test_submitMappedEventInterruptsIdle() {
        let engine = makeEngine(rolls: [0.1])

        let accepted = engine.submit(.celebrationTriggered)

        XCTAssertTrue(accepted)
        XCTAssertEqual(engine.state, .reaction(kind: .celebrate, resumeState: .idle))
        XCTAssertTrue(engine.pendingExternalEvents.isEmpty)
    }

    func test_submitMappedEventInterruptsWalkAndResumes() {
        let engine = makeEngine(rolls: [0.9, 0.0])
        engine.apply(engine.nextAutonomousDecision())
        XCTAssertEqual(engine.state, .walk(direction: .right))

        XCTAssertTrue(engine.submit(.attentionRequested))
        XCTAssertEqual(engine.state, .reaction(kind: .attention, resumeState: .walk(direction: .right)))

        engine.finishReaction()
        XCTAssertEqual(engine.state, .walk(direction: .right))
    }

    func test_submitUnmappedEventOnlyEnqueues() {
        let engine = makeEngine(rolls: [0.1])

        let accepted = engine.submit(.activityStarted(kind: .thinking))

        XCTAssertFalse(accepted)
        XCTAssertEqual(engine.pendingExternalEvents.count, 1)
        XCTAssertEqual(engine.state, .idle)
    }

    func test_reactionIsDroppedDuringDragAndPetted() {
        let engine = makeEngine(rolls: [0.1])
        engine.beginDrag()
        XCTAssertFalse(engine.submit(.celebrationTriggered))
        XCTAssertEqual(engine.state, .drag)

        engine.endDrag()
        engine.pet()
        XCTAssertFalse(engine.submit(.loadSurged))
        XCTAssertEqual(engine.state, .petted(resumeState: .idle))
    }

    func test_newReactionReplacesCurrentAndKeepsResume() {
        let engine = makeEngine(rolls: [0.9, 0.0])
        engine.apply(engine.nextAutonomousDecision())
        XCTAssertTrue(engine.submit(.attentionRequested))
        XCTAssertTrue(engine.submit(.loadSurged))

        XCTAssertEqual(engine.state, .reaction(kind: .heat, resumeState: .walk(direction: .right)))
    }

    func test_reactionKindMapping() {
        XCTAssertEqual(PetExternalEvent.celebrationTriggered.reactionKind, .celebrate)
        XCTAssertEqual(PetExternalEvent.attentionRequested.reactionKind, .attention)
        XCTAssertEqual(PetExternalEvent.loadSurged.reactionKind, .heat)
        XCTAssertEqual(PetExternalEvent.clipboardActivity.reactionKind, .noticed)
        XCTAssertEqual(PetExternalEvent.inputLockChanged(locked: true).reactionKind, .salute)
        XCTAssertEqual(PetExternalEvent.inputLockChanged(locked: false).reactionKind, .celebrate)
        XCTAssertNil(PetExternalEvent.activityStarted(kind: .working).reactionKind)
    }

    func test_reactionFallbackChainEndsAtIdle() {
        // 降级链最后一项必须是 idle（任何资产都有兜底）。
        for kind in PetReactionKind.allCases {
            XCTAssertEqual(kind.animationFallbacks.last, PetAnimationID.idle)
            XCTAssertGreaterThan(kind.duration, 0)
        }
    }

    // MARK: - 调参热更新

    func test_applyTuningTakesEffectImmediately() {
        let engine = makeEngine(rolls: [0.1])
        var tuning = PetBehaviorTuning.default
        tuning.idleStep = 3...3
        engine.apply(tuning: tuning)

        let decision = engine.nextAutonomousDecision()

        // roll 0.1 落在 idle；时长区间固定 3s（时长 roll 0 → 下界 3）。
        XCTAssertEqual(decision.state, .idle)
        XCTAssertEqual(decision.duration, 3, accuracy: 0.0001)
    }
}
