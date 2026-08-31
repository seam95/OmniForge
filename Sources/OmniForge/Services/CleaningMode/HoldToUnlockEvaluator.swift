import Foundation

/// 长按解锁判定（SPEC D4）：从按下时刻起算，持续满 requiredDuration 即满足；
/// 中途松手立即重置。纯值类型，时间全部由调用方注入，可单测。
struct HoldToUnlockEvaluator: Equatable {
    /// 满足解锁所需的持续按压时长（秒）。
    let requiredDuration: TimeInterval

    /// 当前按压的起始时刻；nil 表示未按住。
    private(set) var pressBeganAt: Date?

    init(requiredDuration: TimeInterval = 3) {
        self.requiredDuration = requiredDuration
    }

    /// 是否处于按压中。
    var isHolding: Bool { pressBeganAt != nil }

    /// 记录按压开始；重复按下以最近一次为准。
    mutating func pressBegan(at date: Date) {
        pressBeganAt = date
    }

    /// 记录松手，重置判定。
    mutating func pressEnded() {
        pressBeganAt = nil
    }

    /// 当前时刻是否已满足解锁时长。
    func isSatisfied(at now: Date) -> Bool {
        guard let began = pressBeganAt else { return false }
        return now.timeIntervalSince(began) >= requiredDuration
    }

    /// 当前按压进度（0...1）；未按住时为 0。
    func progress(at now: Date) -> Double {
        guard let began = pressBeganAt, requiredDuration > 0 else { return 0 }
        return min(max(now.timeIntervalSince(began) / requiredDuration, 0), 1)
    }
}
