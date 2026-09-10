import Foundation

/// 帧序号推导（从视图抽出的纯函数，便于单测覆盖时间推进语义）。
enum PetFrameSequencer {
    /// 依据挂钟推导当前图集帧序号。
    /// - Parameters:
    ///   - now: 当前时刻（TimelineView 的帧时刻）。
    ///   - stateEnteredAt: 当前行为状态的进入时刻（一次性动画的时间轴原点）。
    ///   - animation: 目标动画。
    /// - Returns: 图集单元格序号；动画无帧时返回 nil。
    static func frameIndex(
        now: Date,
        stateEnteredAt: Date,
        animation: PetSpriteAsset.Animation
    ) -> Int? {
        guard !animation.frames.isEmpty else { return nil }
        let frameCount = animation.frames.count
        let total = animation.frameDuration * Double(frameCount)
        let phase: TimeInterval
        if animation.loops {
            // 循环动画以挂钟取模，天然连续。
            phase = total > 0
                ? now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
                : 0
        } else {
            // 一次性动画：从状态进入时刻起播，播完停在最后一帧。
            // 时间轴原点必须是「状态进入时刻」，用挂钟取模或恒零相位都会定格首帧。
            phase = min(max(now.timeIntervalSince(stateEnteredAt), 0), total)
        }
        let index = animation.frameDuration > 0 ? Int(phase / animation.frameDuration) : 0
        return animation.frames[min(index, frameCount - 1)]
    }
}
