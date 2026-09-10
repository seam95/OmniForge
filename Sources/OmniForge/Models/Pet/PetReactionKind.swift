import Foundation

/// 反应种类：外部事件触发的一次性状态语义。
/// 每种携带优先级、时长、素材动画 id 与降级链（内置猫缺专用素材时回退）。
enum PetReactionKind: String, Equatable, CaseIterable {
    /// 庆祝（限额重置、输入法解锁）。
    case celebrate
    /// 求助提醒（限额告急）。
    case attention
    /// 热得受不了（CPU 持续高负载）。
    case heat
    /// 好奇注意（剪贴板复制）。
    case noticed
    /// 致意小反应（输入法锁定）。
    case salute

    /// 反应态优先级（drag 8 / petted 7 之下，自主态 2/1 之上）。
    static let priority = 6

    /// 反应时长（秒）——业界一致取值（两家同类产品均为 3 秒回落）。
    var duration: TimeInterval { 3 }

    /// 素材动画 id：celebrate 复用 waving（与抚摸同素材），其余用 petdex 语义行。
    var animationID: String {
        switch self {
        case .celebrate, .salute: return PetAnimationID.petted
        case .attention, .noticed: return PetAnimationID.waiting
        case .heat: return PetAnimationID.failed
        }
    }

    /// 素材降级链：专用动画 → 抚摸 → 空闲（内置猫缺专用素材时逐级回退）。
    var animationFallbacks: [String] {
        [animationID, PetAnimationID.petted, PetAnimationID.idle]
    }

    /// 反应期间的打断裁决：用户主动交互（拖拽/抚摸）进行中到达的反应一律丢弃。
    /// 同级反应到达时替换并刷新计时。
}

/// 外部事件：应用内数据源 → 协调器冷却裁决 → 行为引擎的输入形状。
/// 一期仅锁定形状未分发；二期起引擎对已映射事件做真实反应分发，
/// 未映射事件（activityStarted/Ended，三期 Agent 预留）仍只入队。
enum PetExternalEvent: Equatable {
    /// 外部活动开始（如 Agent 开始思考）——三期 Agent 预留。
    case activityStarted(kind: PetActivityKind)
    /// 外部活动结束——三期 Agent 预留。
    case activityEnded(kind: PetActivityKind)
    /// 需要提醒（额度告急）。
    case attentionRequested
    /// 庆祝（限额重置）。
    case celebrationTriggered
    /// 系统负载升高（CPU 持续超阈）。
    case loadSurged
    /// 剪贴板出现新复制内容。
    case clipboardActivity
    /// 输入法锁定状态变化。
    case inputLockChanged(locked: Bool)

    /// 映射为反应种类；未映射事件返回 nil（三期预留，引擎只入队）。
    var reactionKind: PetReactionKind? {
        switch self {
        case .celebrationTriggered: return .celebrate
        case .attentionRequested: return .attention
        case .loadSurged: return .heat
        case .clipboardActivity: return .noticed
        case .inputLockChanged(let locked): return locked ? .salute : .celebrate
        case .activityStarted, .activityEnded: return nil
        }
    }
}

/// 外部活动类别（三期 Agent 扩展位）。
enum PetActivityKind: String, Equatable {
    case thinking
    case working
    case waiting
}
