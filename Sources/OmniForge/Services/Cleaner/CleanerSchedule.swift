import Foundation

/// 自动清理何时运行。纯日历数学，与定时器隔离，便于测试固定每个边界。
enum CleanerSchedule {
    enum Frequency: String, CaseIterable, Identifiable {
        case off, daily, weekly

        var id: String { rawValue }

        static func sanitized(_ raw: String) -> Frequency {
            Frequency(rawValue: raw) ?? .off
        }
    }

    /// 严格在 `date` 之后的下一次清理触发时刻。
    /// 每周运行使用 `weekday`（1 = 周日 … 7 = 周六，日历约定）；每日运行忽略它。关闭永不触发。
    static func nextFireDate(after date: Date,
                             frequency: Frequency,
                             hour: Int,
                             minute: Int,
                             weekday: Int,
                             calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = min(max(hour, 0), 23)
        components.minute = min(max(minute, 0), 59)
        switch frequency {
        case .off:
            return nil
        case .daily:
            break
        case .weekly:
            components.weekday = min(max(weekday, 1), 7)
        }
        return calendar.nextDate(after: date, matching: components,
                                 matchingPolicy: .nextTime)
    }

    /// 调度选择器的 12 小时制换算，由测试固定 —— 午夜和正午总会绊倒人。
    static func hour24(hour12: Int, isPM: Bool) -> Int {
        let clamped = min(max(hour12, 1), 12)
        return (clamped % 12) + (isPM ? 12 : 0)
    }

    static func hour12Components(fromHour24 hour: Int) -> (hour12: Int, isPM: Bool) {
        let clamped = min(max(hour, 0), 23)
        let hour12 = clamped % 12 == 0 ? 12 : clamped % 12
        return (hour12, clamped >= 12)
    }

    /// Mac 关机或睡眠期间是否错过了已调度的运行：上次运行之后的触发时刻已落入过去。
    static func missedRun(now: Date,
                          lastRun: Date?,
                          frequency: Frequency,
                          hour: Int,
                          minute: Int,
                          weekday: Int,
                          calendar: Calendar = .current) -> Bool {
        guard frequency != .off else { return false }
        // 从未运行过：调度从现在开始计数，首次启用不搞突然追补清理。
        guard let lastRun else { return false }
        guard let due = nextFireDate(after: lastRun, frequency: frequency,
                                     hour: hour, minute: minute,
                                     weekday: weekday, calendar: calendar) else { return false }
        return due <= now
    }
}
