import Foundation

// MARK: - 趋势点

/// 趋势图单个数据点（日期 + token 总量）。
struct UsageTrendPoint: Equatable, Identifiable {
    var date: Date
    var tokens: Int
    var id: Date { date }
}

// MARK: - 趋势构建器

/// 按趋势周期从日聚合 / 当日半小时桶派生趋势点序列 — 纯函数。
///
/// 口径（SPEC 2.3）：
/// - `day`：当日逐时（半小时桶按小时归并；补零至当前小时，保证曲线连续）；
/// - `week`：近 7 日逐日（含今日，缺日补零）；
/// - `month`：近 30 日逐日（含今日，缺日补零）；
/// - `total`：全部历史按月（含缺月补零；视觉上最多展示近 24 个月，对齐 TokenTracker）。
/// 对应周期无任何数据时返回空序列（视图显示占位）。
enum UsageTrendBuilder {
    static let totalMonthSpan = 24

    static func make(
        period: TokenTrendPeriod,
        daily: [UsageDayProviderAggregate],
        hourlyBuckets: [UsageBucketState],
        now: Date,
        calendar: Calendar
    ) -> [UsageTrendPoint] {
        switch period {
        case .day:
            return makeDay(hourlyBuckets: hourlyBuckets, now: now, calendar: calendar)
        case .week:
            return makeDaily(daily: daily, daysBack: 7, now: now, calendar: calendar)
        case .month:
            return makeDaily(daily: daily, daysBack: 30, now: now, calendar: calendar)
        case .total:
            return makeMonthly(daily: daily, now: now, calendar: calendar)
        }
    }

    /// 当日逐时：半小时桶按小时归并，补零至当前小时。
    private static func makeDay(
        hourlyBuckets: [UsageBucketState],
        now: Date,
        calendar: Calendar
    ) -> [UsageTrendPoint] {
        guard !hourlyBuckets.isEmpty else { return [] }
        let todayStart = calendar.startOfDay(for: now)
        var byHour: [Date: Int] = [:]
        for state in hourlyBuckets {
            guard let hourStart = calendar.dateInterval(of: .hour, for: state.key.bucketStart)?.start else { continue }
            byHour[hourStart, default: 0] += state.usage.totalTokens
        }
        let currentHour = calendar.component(.hour, from: now)
        var points: [UsageTrendPoint] = []
        for hour in 0...currentHour {
            guard let date = calendar.date(byAdding: .hour, value: hour, to: todayStart) else { continue }
            points.append(UsageTrendPoint(date: date, tokens: byHour[date] ?? 0))
        }
        return points
    }

    /// 近 N 日逐日：缺日补零。
    private static func makeDaily(
        daily: [UsageDayProviderAggregate],
        daysBack: Int,
        now: Date,
        calendar: Calendar
    ) -> [UsageTrendPoint] {
        let byDay = daily.mergedByDay
        guard !byDay.isEmpty else { return [] }
        let todayStart = calendar.startOfDay(for: now)
        var points: [UsageTrendPoint] = []
        for offset in 0..<daysBack {
            guard let day = calendar.date(byAdding: .day, value: -(daysBack - 1 - offset), to: todayStart) else { continue }
            points.append(UsageTrendPoint(date: day, tokens: byDay[day]?.totalTokens ?? 0))
        }
        return points
    }

    /// 全部历史按月：缺月补零；最早月份早于近 24 个月窗口时截断。
    private static func makeMonthly(
        daily: [UsageDayProviderAggregate],
        now: Date,
        calendar: Calendar
    ) -> [UsageTrendPoint] {
        let byDay = daily.mergedByDay
        guard !byDay.isEmpty else { return [] }
        guard let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }

        var byMonth: [Date: Int] = [:]
        for (day, entry) in byDay {
            guard let monthStart = calendar.dateInterval(of: .month, for: day)?.start else { continue }
            byMonth[monthStart, default: 0] += entry.totalTokens
        }

        // 最早数据月（与近 24 个月窗口取较晚者，控制曲线宽度）。
        let earliestDataMonth = byMonth.keys.min() ?? currentMonthStart
        let windowStart = calendar.date(byAdding: .month, value: -(totalMonthSpan - 1), to: currentMonthStart)
            ?? currentMonthStart
        let start = max(earliestDataMonth, windowStart)

        var points: [UsageTrendPoint] = []
        var cursor = start
        while cursor <= currentMonthStart {
            points.append(UsageTrendPoint(date: cursor, tokens: byMonth[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return points
    }
}
