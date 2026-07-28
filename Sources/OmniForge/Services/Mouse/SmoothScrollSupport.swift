import Foundation

/// 平滑鼠标滚轮滚动的纯数学，与 AppKit 解耦，便于单元测试。
///
/// 每个离散滚轮刻度向按轴维护的「剩余」距离预算累加一个步长；
/// 随后动画帧发出剩余距离的一个比例，使原本的跳跃衰减为一段
/// 收尾时逐渐减速的短滑行。
enum SmoothScrollSupport {
    /// 动画帧时长。每秒 60 步读起来连续，且远低于事件投递可承受的上限。
    static let frameInterval: TimeInterval = 1.0 / 60.0

    /// 每帧发出剩余距离的比例。每秒 60 帧、0.18 时一个刻度约在四分之一秒落地。
    static let emitFactor: Double = 0.18

    /// 小于此阈值的余量在最后一帧一次性发出。
    static let finishThreshold: Double = 1.0

    /// 单个滚轮刻度的可调距离（像素）。
    static let stepRange = 20...100
    static let defaultStep = 40

    /// 新滚轮刻度到达后的剩余距离。反向滚动会丢弃剩余量而不是与之对抗，
    /// 使方向切换立即响应。
    static func remaining(afterTicks ticks: Double, step: Double, current: Double) -> Double {
        let added = ticks * step
        guard added != 0 else { return current }
        if current != 0, (added < 0) != (current < 0) {
            return added
        }
        return current + added
    }

    /// 当前剩余预算下本帧应发出的距离：剩余的一个比例，至少 1 像素
    /// 以免滑行卡住，余量足够小时则一次性收尾。
    static func frameDelta(remaining: Double) -> Double {
        guard remaining != 0 else { return 0 }
        let magnitude = abs(remaining)
        if magnitude <= finishThreshold { return remaining }
        let emitted = max(magnitude * emitFactor, 1.0)
        return remaining < 0 ? -emitted : emitted
    }

    /// 将持久化的 step 钳制到允许区间（0 或脏值回退到默认值）。
    static func sanitizedStep(_ value: Int) -> Int {
        guard value != 0 else { return defaultStep }
        return min(max(value, stepRange.lowerBound), stepRange.upperBound)
    }

    /// 系统只对连续像素事件（而非离散滚轮刻度）应用自然滚动方向
    /// （实测两种事件均投递过），因此开启自然滚动时，滑行必须预先
    /// 翻转 delta，回放才能保持滚轮方向。
    static func postedDelta(_ frameDelta: Double, naturalScrolling: Bool) -> Double {
        naturalScrolling ? -frameDelta : frameDelta
    }
}
