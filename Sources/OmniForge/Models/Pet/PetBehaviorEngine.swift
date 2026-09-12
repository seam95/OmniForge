import CoreGraphics
import Foundation

/// 自主行为态（转移矩阵维度）。
/// 交互态（drag / petted）不参与矩阵——它们由用户触发并必然回落到自主层。
enum PetAutonomyKind: String, CaseIterable, Hashable {
    case idle
    case walkLeft
    case walkRight
    /// 玩耍（原地卖萌小动作）。
    case frolic
    /// 蹦跳（原地跳一下）。
    case hop

    /// 转为对外行为状态。
    var behaviorState: PetBehaviorState {
        switch self {
        case .idle: return .idle
        case .walkLeft: return .walk(direction: .left)
        case .walkRight: return .walk(direction: .right)
        case .frolic: return .frolic
        case .hop: return .hop
        }
    }
}

/// 行为调参（集中注入，避免魔法数字散落）。
/// 稳态 idle 时长占比由「行分布 × 各态时长」共同决定，可被单测断言。
struct PetBehaviorTuning: Equatable {
    /// 好动程度 0（最安静）… 1（最活泼），默认 0.5。
    /// 作用方式：缩放 idle 行的自环权重（安静档自环翻倍、活泼档压至近零），行内再归一化。
    var activityLevel: Double

    /// 单次 idle 停留时长区间（秒）。
    var idleStep: ClosedRange<TimeInterval>
    /// 单次行走时长区间（秒）。
    var walkStep: ClosedRange<TimeInterval>
    /// 单次玩耍时长区间（秒）。
    var frolicStep: ClosedRange<TimeInterval>
    /// 单次蹦跳时长区间（秒）。
    var hopStep: ClosedRange<TimeInterval>
    /// 行走速度（点/秒）。
    var walkSpeed: CGFloat

    /// 好动程度档位（UI 三档映射）。
    enum ActivityPreset: String, CaseIterable {
        case quiet
        case balanced
        case lively

        var activityLevel: Double {
            switch self {
            case .quiet: return 0.2
            case .balanced: return 0.5
            case .lively: return 0.85
            }
        }

        var autonomyKindRange: [PetAutonomyKind] { PetAutonomyKind.allCases }
    }

    static let `default` = PetBehaviorTuning(
        activityLevel: ActivityPreset.balanced.activityLevel,
        idleStep: 2...6,
        walkStep: 1...2.5,
        frolicStep: 1.2...2.2,
        hopStep: 0.8...1.4,
        walkSpeed: 30
    )

    /// 基准转移矩阵（未含好动度缩放）。
    /// 设计参照业界马尔可夫桌宠：idle 行自环为主；行走行以回归 idle 为主，
    /// 停留时长由自环权重的期望步数内生控制，而非独立的次数权重。
    private static let baseMatrix: [PetAutonomyKind: [PetAutonomyKind: Double]] = [
        // idle 行小权重分给玩耍/蹦跳（自主小动作）；好动度缩放 idle 自环后归一化，
        // 活泼档三者概率同步升高。
        .idle: [.idle: 0.55, .walkLeft: 0.15, .walkRight: 0.15, .frolic: 0.075, .hop: 0.075],
        .walkLeft: [.idle: 0.70, .walkLeft: 0.15, .walkRight: 0.15],
        .walkRight: [.idle: 0.70, .walkLeft: 0.15, .walkRight: 0.15],
        // 一次性自主小动作：播完必回 idle 重新掷骰。
        .frolic: [.idle: 1],
        .hop: [.idle: 1],
    ]

    /// 好动度对 idle 自环权重的乘数：0 → ×2（更安静），0.5 → ×1（基准），1 → ×0（idle 结束必走）。
    private var idleSelfWeightMultiplier: Double {
        max(0, 2.0 - 2.0 * min(max(activityLevel, 0), 1))
    }

    /// 含好动度缩放的转移权重行（已归一化，可直接加权随机）。
    /// - Parameter availableKinds: 素材可支撑的自主态集合——缺素材的列置零后重归一化
    ///   （对齐业界禁用列机制：素材缺行时矩阵自动收缩，相对比例不变）。
    func transitionWeights(
        from kind: PetAutonomyKind,
        available: Set<PetAutonomyKind> = Set(PetAutonomyKind.allCases)
    ) -> [PetAutonomyKind: Double] {
        let base = Self.baseMatrix[kind] ?? [:]
        var row = base.filter { available.contains($0.key) }
        if kind == .idle {
            row[.idle] = (base[.idle] ?? 0) * idleSelfWeightMultiplier
        }
        let total = row.values.reduce(0, +)
        guard total > 0 else { return [.idle: 1] }
        return row.mapValues { $0 / total }
    }

    /// 指定态的单步时长区间。
    func stepRange(for kind: PetAutonomyKind) -> ClosedRange<TimeInterval> {
        switch kind {
        case .idle: return idleStep
        case .walkLeft, .walkRight: return walkStep
        case .frolic: return frolicStep
        case .hop: return hopStep
        }
    }
}

/// 行为引擎：驱动宠物状态流转。
/// 不依赖 AppKit / 窗口，可在单测中完整覆盖。
/// 决策时机与业界一致：仅在当前状态时长到期时掷骰（低频），帧循环只推进位移与动画。
@MainActor
final class PetBehaviorEngine {
    /// 当前状态（对外展示，含交互态）。
    private(set) var state: PetBehaviorState = .idle

    /// 当前自主层矩阵态（矩阵行选择依据；交互态期间保持不变，回落后续掷）。
    private(set) var autonomy: PetAutonomyKind = .idle

    /// 待处理的外部事件队列（一期恒为空，二期由数据源填充）。
    private(set) var pendingExternalEvents: [PetExternalEvent] = []

    private var randomSource: PetRandomSource
    private var tuning: PetBehaviorTuning
    /// 素材可支撑的自主态（缺素材的行为从矩阵剔除；默认全量）。
    private var availableKinds: Set<PetAutonomyKind> = Set(PetAutonomyKind.allCases)

    init(
        randomSource: PetRandomSource = SystemPetRandomSource(),
        tuning: PetBehaviorTuning = .default
    ) {
        self.randomSource = randomSource
        self.tuning = tuning
    }

    /// 更新调参（好动度切换等）。
    func apply(tuning newTuning: PetBehaviorTuning) {
        tuning = newTuning
    }

    /// 更新素材可支撑的自主态（换宠物后按素材行收缩矩阵）。
    func apply(availableKinds kinds: Set<PetAutonomyKind>) {
        availableKinds = kinds
    }

    // MARK: - 决策

    /// 从当前自主态出发的下一步决策（矩阵行加权随机，时长按目标态采样）。
    func nextAutonomousDecision() -> PetBehaviorDecision {
        let weights = tuning.transitionWeights(from: autonomy, available: availableKinds)
        let next = pickWeighted(weights) ?? .idle
        autonomy = next
        let duration = randomDuration(in: tuning.stepRange(for: next))
        return PetBehaviorDecision(
            state: next.behaviorState,
            horizontalDelta: 0,
            duration: duration
        )
    }

    /// 行走状态每帧的水平位移（已含方向）。
    func walkDelta(dt: TimeInterval) -> CGFloat {
        guard case .walk(let direction) = state else { return 0 }
        return tuning.walkSpeed * CGFloat(dt) * direction.horizontalSign
    }

    // MARK: - 状态转移

    /// 应用一次自主决策（进入 idle 或 walk）。
    func apply(_ decision: PetBehaviorDecision) {
        state = decision.state
        syncAutonomyIfNeeded()
    }

    /// 采样指定自主态的单步时长。
    /// 供 Manager 硬切回 idle 的路径（行走结束 / 抚摸恢复 / 松手拖拽 / 重置位置等）
    /// 显式取一次停留时长——这些路径不经过矩阵决策，若沿用归零的计时器，
    /// idle 会在下一帧立即到期重掷，观感为「走完不停、一直重复走动」。
    func sampleDuration(for kind: PetAutonomyKind) -> TimeInterval {
        randomDuration(in: tuning.stepRange(for: kind))
    }

    /// 开始拖拽（任意状态可进入）。
    func beginDrag() {
        state = .drag
    }

    /// 拖拽结束：宠物悬停在松手处并回到 idle（无重力掉落）。
    func endDrag() {
        state = .idle
        autonomy = .idle
    }

    /// 单击抚摸：从当前状态进入一次性动画，记录恢复目标。
    /// 已在抚摸中则引擎态不变（不重入；连击由 Manager 重置计时实现）。
    /// 反应进行中被抚摸打断时，沿用反应记录的恢复态（不丢被打断的自主行为）。
    func pet() {
        guard case .petted = state else {
            let resume: PetResumeState
            switch state {
            case .walk(let direction): resume = .walk(direction: direction)
            case .reaction(_, let reactionResume): resume = reactionResume
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
        syncAutonomyIfNeeded()
    }

    /// 外部反应：打断自主行为进入一次性反应态，播完回 `resumeState`。
    /// 打断裁决按 `PetInterruptLevel`：等级高于当前状态的反应接纳（drag/petted 之下）
    /// ——用户主动交互（拖拽/抚摸）进行中**丢弃**反应（不与用户争抢）；
    /// 反应进行中到达的新反应**同级替换并刷新**；自主行为（idle/walk/frolic/hop）一律可打断。
    @discardableResult
    func react(to kind: PetReactionKind) -> Bool {
        switch state.interruptLevel {
        case .drag, .petted:
            return false
        case .reaction:
            // 同级替换：保留原 resumeState（打断前的自主态语义不变）。
            if case .reaction(_, let resume) = state {
                state = .reaction(kind: kind, resumeState: resume)
            }
            return true
        case .autonomous:
            // 一次性自主小动作（frolic/hop）被打断后回到 idle（无需续播小动作）。
            let resume: PetResumeState
            switch state {
            case .walk(let direction): resume = .walk(direction: direction)
            default: resume = .idle
            }
            state = .reaction(kind: kind, resumeState: resume)
            return true
        }
    }

    /// 反应播完，回到被打断前的状态。
    func finishReaction() {
        guard case .reaction(_, let resume) = state else { return }
        state = resume.behaviorState
        syncAutonomyIfNeeded()
    }

    /// 当前反应种类（非反应态返回 nil）。
    var currentReaction: PetReactionKind? {
        guard case .reaction(let kind, _) = state else { return nil }
        return kind
    }

    /// 显示器配置变更等外部原因强制回到 idle。
    func resetToIdle() {
        state = .idle
        autonomy = .idle
    }

    // MARK: - 二期事件入口（形状锁定）

    /// 提交外部事件：已映射事件即时分发为反应；未映射事件（三期 Agent 预留）只入队。
    @discardableResult
    func submit(_ event: PetExternalEvent) -> Bool {
        if let kind = event.reactionKind {
            return react(to: kind)
        }
        pendingExternalEvents.append(event)
        return false
    }

    /// 清空待处理事件（测试与生命周期收尾用）。
    func drainExternalEvents() {
        pendingExternalEvents.removeAll()
    }

    // MARK: - 私有

    /// 状态与矩阵态同步（决策应用 / 抚摸结束后的兜底）。
    private func syncAutonomyIfNeeded() {
        switch state {
        case .idle: autonomy = .idle
        case .walk(let direction): autonomy = direction == .left ? .walkLeft : .walkRight
        case .frolic: autonomy = .frolic
        case .hop: autonomy = .hop
        case .drag, .petted, .reaction: break
        }
    }

    private func pickWeighted(_ weights: [PetAutonomyKind: Double]) -> PetAutonomyKind? {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return nil }
        var roll = randomSource.nextUnit() * total
        for (kind, weight) in weights.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            roll -= weight
            if roll < 0 { return kind }
        }
        return weights.keys.first
    }

    private func randomDuration(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        let unit = randomSource.nextUnit()
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}

