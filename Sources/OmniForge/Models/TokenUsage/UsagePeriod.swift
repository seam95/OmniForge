import Foundation

// MARK: - 用量统计周期

/// 用量统计周期（今日 / 本周 / 本月）。
enum TokenUsagePeriod: String, Codable, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }
}

// MARK: - 周期窗口

/// 周期窗口起点/终点（UTC 半小时桶与本地日界对齐）— 纯函数。
///
/// 窗口为半开区间 `[start, end)`，直接与 `UsageStoring.loadBuckets(from:to:)` 对齐：
/// - `.today`：今日零点 ~ 明日零点；
/// - `.week`：本周起始（`calendar.firstWeekday` 决定，如周日起）~ 下周起始；
/// - `.month`：本月 1 日零点 ~ 下月 1 日零点。
enum UsagePeriodWindow {
    static func window(
        for period: TokenUsagePeriod,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let todayStart = calendar.startOfDay(for: now)
        switch period {
        case .today:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
                return nil
            }
            return (todayStart, tomorrow)
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return nil
            }
            return (interval.start, interval.end)
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: now) else {
                return nil
            }
            return (interval.start, interval.end)
        }
    }

    /// 系列起点（用于「周期内逐日」序列）：周期的首个本地日零点。
    static func seriesStart(
        for window: (start: Date, end: Date),
        calendar: Calendar
    ) -> Date {
        calendar.startOfDay(for: window.start)
    }
}
