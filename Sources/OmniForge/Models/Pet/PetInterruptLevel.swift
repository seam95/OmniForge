import Foundation

/// 行为态的反应接纳等级：仅用于「外部反应能否打断当前状态」的裁决。
/// 显式声明等级值，避免依赖枚举 case 声明顺序隐式比较。
/// 看向与悬停是渲染覆盖，不属于行为层，不进入该表。
enum PetInterruptLevel: Int {
    /// 自主行为（idle / walk / frolic / hop）：反应可打断。
    case autonomous = 1
    /// 反应中：同级到达的反应替换并刷新。
    case reaction = 2
    /// 抚摸中：用户主动交互，反应丢弃。
    case petted = 3
    /// 拖拽（含投掷）：用户主动交互，反应丢弃。
    case drag = 4
}

extension PetBehaviorState {
    /// 当前状态的反应接纳等级（`react(to:)` 裁决用）。
    var interruptLevel: PetInterruptLevel {
        switch self {
        case .idle, .walk, .frolic, .hop: return .autonomous
        case .reaction: return .reaction
        case .petted: return .petted
        case .drag: return .drag
        }
    }
}
