import Foundation

/// LimitPace 步速算法 — 纯函数，无 UI / 时钟依赖（参考 07，按理解重写，语义对齐）。
/// 回答"按当前速度，会不会在重置前用完"：把实际用量与均匀消耗期望对比。
enum LimitPace {
    /// 结果模型 + 投影（耗尽 ETA / 预计结束值）
    struct Result: Equatable {
        /// 进度条上的刻度位置（0…100），nil = 不画（用量 < 5% 或窗口不可信）
        var pacePercent: Double?
        /// 是否超前（用量高于期望 + 容差）
        var paceOver = false
        /// 到现在均匀应消耗的 %
        var expectedPercent: Int?
        /// 会在 reset 前用完时的预计剩余时长（紧凑格式 "3h"）
        var runsOutEta: String?
        /// 不会用完时，预计 reset 时的 %
        var projectedEnd: Int?
    }

    /// ① 期望已用比例（均匀消耗下现在该用多少），clamp 到 0…1。
    static func expectedUsedFraction(windowSeconds: Double, secondsUntilReset: Double) -> Double? {
        guard windowSeconds > 0, windowSeconds.isFinite else { return nil }
        let elapsed = windowSeconds - secondsUntilReset
        let fraction = elapsed / windowSeconds
        guard fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    /// ② 超前判定（3 个百分点容差防抖）。
    static func isOverPace(
        usedFraction: Double,
        expectedFraction: Double,
        tolerance: Double = 0.03
    ) -> Bool {
        usedFraction > expectedFraction + tolerance
    }

    /// ③ 结果模型 + 投影。
    /// - `remainingMode`：进度条数值口径为"剩余"时，刻度画在 `1 - expected` 位置。
    /// - `minimumPaceFraction`：用量低于该比例不画刻度（新窗口不在空轨道上飘刻度）。
    static func compute(
        usedFraction: Double,
        windowSeconds: Double,
        secondsUntilReset: Double,
        remainingMode: Bool,
        minimumPaceFraction: Double = 0.05
    ) -> Result {
        guard let expected = expectedUsedFraction(
            windowSeconds: windowSeconds,
            secondsUntilReset: secondsUntilReset
        ) else {
            return Result()
        }
        let used = min(max(usedFraction, 0), 1)
        let over = isOverPace(usedFraction: used, expectedFraction: expected)
        var result = Result(
            paceOver: over,
            expectedPercent: Int((expected * 100).rounded())
        )

        // 用量 ≥5% 才画刻度
        if used >= minimumPaceFraction {
            result.pacePercent = (remainingMode ? 1 - expected : expected) * 100
        }

        // 投影：rate = used / elapsed；projectedAtReset = used / expected
        let elapsed = windowSeconds - secondsUntilReset
        if elapsed > 0, used > 0, expected > 0 {
            let rate = used / elapsed
            let projected = used / expected
            if projected >= 1 {
                // 会在 reset 前耗尽 → ETA
                result.runsOutEta = durationString((1 - used) / rate)
            } else {
                // 不会耗尽 → 预计 reset 时的用量
                result.projectedEnd = Int((projected * 100).rounded())
            }
        }
        return result
    }

    /// ④ 紧凑时长格式化：`45m` / `3h` / `2d`。
    static func durationString(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600
        if h >= 24 { return "\(h / 24)d" }
        if h > 0 { return "\(h)h" }
        return "\(s / 60)m"
    }
}
