import CoreGraphics
import Foundation

/// 桌宠行为状态：任一时刻所处的动作阶段。
/// 由行为引擎驱动，外部只能通过反应事件间接影响，不允许直接置位。
enum PetBehaviorState: Equatable {
    /// 空闲：原地待机。
    case idle
    /// 行走：沿地面移动，`direction` 为水平朝向。
    case walk(direction: PetDirection)
    /// 掉落：拖到空中松手后的重力下落。
    case fall
    /// 被拖拽：窗口跟随鼠标。
    case drag
    /// 被抚摸：播放一次性动画，播完回到 `resumeState`。
    case petted(resumeState: PetResumeState)
}

/// 水平朝向。
enum PetDirection: Equatable {
    case left
    case right

    var reversed: PetDirection { self == .left ? .right : .left }

    /// 朝右为正方向。
    var horizontalSign: CGFloat { self == .right ? 1 : -1 }
}

/// 被抚摸结束后要恢复的状态（`petted` 是可打断的一次性动作）。
enum PetResumeState: Equatable {
    case idle
    case walk(direction: PetDirection)

    /// 转回行为状态。
    var behaviorState: PetBehaviorState {
        switch self {
        case .idle: return .idle
        case .walk(let direction): return .walk(direction: direction)
        }
    }
}

/// 行为引擎的决策输出：下一步该处于什么状态、朝哪个方向走多远。
/// 纯值类型，便于单测断言。
struct PetBehaviorDecision: Equatable {
    let state: PetBehaviorState
    /// 本步的水平位移（点，已含方向符号）。
    let horizontalDelta: CGFloat
    /// 该状态持续时长（秒）。
    let duration: TimeInterval
}

/// 随机源抽象：测试注入固定序列，生产用系统随机。
protocol PetRandomSource {
    /// 返回 [0, 1) 均匀分布随机数。
    func nextUnit() -> Double
}

/// 生产随机源。
struct SystemPetRandomSource: PetRandomSource {
    func nextUnit() -> Double { Double.random(in: 0..<1) }
}

/// 可复现随机源：按固定序列循环取值，测试专用。
/// 引用类型，满足协议的非 mutating 要求同时保留内部游标。
final class SeededPetRandomSource: PetRandomSource {
    private let values: [Double]
    private var cursor = 0

    init(values: [Double]) {
        self.values = values.isEmpty ? [0.5] : values
    }

    func nextUnit() -> Double {
        let value = values[cursor]
        cursor = (cursor + 1) % values.count
        return value
    }
}
