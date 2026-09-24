import Foundation

/// 帧序号推导（从视图抽出的纯函数，便于单测覆盖时间推进语义）。
enum PetFrameSequencer {
    /// 依据挂钟推导当前图集帧序号。
    /// - Parameters:
    ///   - now: 当前时刻（TimelineView 的帧时刻）。
    ///   - stateEnteredAt: 当前行为状态的进入时刻（一次性动画的时间轴原点）。
    ///   - animation: 目标动画。
    /// - Returns: 图集单元格序号；动画无帧时返回 nil。
    ///
    /// 帧时长可为非均匀（`animation.frameDurations`）：按逐帧累计时长推进，
    /// 而非按 `帧序号 = 相位 / 单帧时长` 折算。参考实现的 idle 即
    /// `280,110,110,140,140,320` ms，用均匀折算会抹掉「慢起-快呼吸-慢收」的节奏。
    static func frameIndex(
        now: Date,
        stateEnteredAt: Date,
        animation: PetSpriteAsset.Animation
    ) -> Int? {
        guard !animation.frames.isEmpty else { return nil }
        let frameCount = animation.frames.count
        let durations = animation.effectiveFrameDurations
        let total = animation.totalDuration
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
        // 逐帧累计推进：找到第一个「累计时长 > phase」的帧。
        var accumulated: TimeInterval = 0
        var index = frameCount - 1
        for frame in 0..<frameCount {
            accumulated += durations[frame]
            if phase < accumulated {
                index = frame
                break
            }
        }
        return animation.frames[index]
    }
}
