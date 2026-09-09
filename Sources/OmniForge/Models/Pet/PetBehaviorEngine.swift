import CoreGraphics
import Foundation

/// 二期事件入口：外部状态（系统负载、Agent 会话等）驱动宠物反应的提交形状。
/// 一期无调用方、无分发逻辑，仅锁定接口以免后续接入时改动引擎内核。
enum PetExternalEvent: Equatable {
    /// 外部活动开始（如 Agent 开始思考）。
    case activityStarted(kind: PetActivityKind)
    /// 外部活动结束。
    case activityEnded(kind: PetActivityKind)
    /// 需要提醒（如等待用户确认）。
    case attentionRequested
    /// 庆祝（如任务完成）。
    case celebrationTriggered
}

/// 外部活动类别（二期扩展位，一期不产生）。
enum PetActivityKind: String, Equatable {
    case thinking
    case working
    case waiting
}

/// 行为引擎：驱动宠物状态流转。
/// 不依赖 AppKit / 窗口，可在单测中完整覆盖。
@MainActor
final class PetBehaviorEngine {
    /// 当前状态。
    private(set) var state: PetBehaviorState = .idle

    /// 待处理的外部事件队列（一期恒为空，二期由数据源填充）。
    private(set) var pendingExternalEvents: [PetExternalEvent] = []

    private let randomSource: PetRandomSource
    /// idle 状态权重（其余归 walk）。
    private let idleWeight: Double
    /// 单次 idle 持续时长范围（秒）。
    private let idleDurationRange: ClosedRange<TimeInterval>
    /// 单次 walk 持续时长范围（秒）。
    private let walkDurationRange: ClosedRange<TimeInterval>
    /// 行走速度（点/秒）。
    private let walkSpeed: CGFloat

    init(
        randomSource: PetRandomSource = SystemPetRandomSource(),
        idleWeight: Double = 0.6,
        idleDurationRange: ClosedRange<TimeInterval> = 2.0...6.0,
        walkDurationRange: ClosedRange<TimeInterval> = 2.0...5.0,
        walkSpeed: CGFloat = 40
    ) {
        self.randomSource = randomSource
        self.idleWeight = idleWeight
        self.idleDurationRange = idleDurationRange
        self.walkDurationRange = walkDurationRange
        self.walkSpeed = walkSpeed
    }

    // MARK: - 决策

    /// 从 idle 出发做一次加权随机决策，返回下一步状态与持续时长。
    func nextIdleDecision() -> PetBehaviorDecision {
        let roll = randomSource.nextUnit()
        if roll < idleWeight {
            return PetBehaviorDecision(
                state: .idle,
                horizontalDelta: 0,
                duration: randomDuration(in: idleDurationRange)
            )
        }
        let direction: PetDirection = randomSource.nextUnit() < 0.5 ? .left : .right
        return PetBehaviorDecision(
            state: .walk(direction: direction),
            horizontalDelta: 0,
            duration: randomDuration(in: walkDurationRange)
        )
    }

    /// 行走状态每帧的水平位移（已含方向）。
    func walkDelta(dt: TimeInterval) -> CGFloat {
        guard case .walk(let direction) = state else { return 0 }
        return walkSpeed * CGFloat(dt) * direction.horizontalSign
    }

    // MARK: - 状态转移

    /// 应用一次决策（进入 idle 或 walk）。
    func apply(_ decision: PetBehaviorDecision) {
        state = decision.state
    }

    /// 开始拖拽（任意状态可进入）。
    func beginDrag() {
        state = .drag
    }

    /// 拖拽结束：宠物悬停在松手处并回到 idle（无重力掉落）。
    func endDrag() {
        state = .idle
    }

    /// 单击抚摸：从当前状态进入一次性动画，记录恢复目标。
    /// 已在抚摸中则忽略（不重入）。
    func pet() {
        guard case .petted = state else {
            let resume: PetResumeState
            switch state {
            case .walk(let direction): resume = .walk(direction: direction)
            default: resume = .idle
            }
            state = .petted(resumeState: resume)
            return
        }
    }

    /// 抚摸动画播完，回到记录的状态。
    func finishPetted() {
        guard case .petted(let resume) = state else { return }
        state = resume.behaviorState
    }

    /// 显示器配置变更等外部原因强制回到 idle。
    func resetToIdle() {
        state = .idle
    }

    // MARK: - 二期事件入口（形状锁定）

    /// 提交外部事件。一期只入队，不产生行为影响；
    /// 二期在此扩展为真实反应分发。
    func submit(_ event: PetExternalEvent) {
        pendingExternalEvents.append(event)
    }

    /// 清空待处理事件（测试与生命周期收尾用）。
    func drainExternalEvents() {
        pendingExternalEvents.removeAll()
    }

    private func randomDuration(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        let unit = randomSource.nextUnit()
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
