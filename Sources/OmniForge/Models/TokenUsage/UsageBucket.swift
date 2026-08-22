import Foundation

// MARK: - 半小时桶

/// 聚合键：`(provider, model, 半小时桶)`（参考 02；GRDB 主键）。
struct UsageBucketKey: Hashable {
    var provider: TokenUsageProvider
    var model: String
    /// UTC 半小时桶起点。
    var bucketStart: Date
}

/// 半小时桶累计状态 — 写库即「累计快照」而非增量（幂等 upsert 的语义前提）。
struct UsageBucketState: Equatable {
    var key: UsageBucketKey
    var usage: TokenUsage
    var conversationCount: Int

    static func empty(_ key: UsageBucketKey) -> UsageBucketState {
        UsageBucketState(key: key, usage: .zero, conversationCount: 0)
    }

    func adding(usage delta: TokenUsage, conversations: Int) -> UsageBucketState {
        UsageBucketState(
            key: key,
            usage: usage.adding(delta),
            conversationCount: conversationCount + conversations
        )
    }
}

// MARK: - 面板用量快照

/// 周期化用量快照（今日 / 本周 / 本月聚合后可复用）。
struct TokenUsageOverview: Equatable {
    struct DayPoint: Equatable {
        var dayStart: Date
        var totalTokens: Int
    }

    /// 周期内 token 总量（今日 / 本周 / 本月）。
    var totalTokens: Int
    /// 周期内会话数。
    var conversations: Int
    /// 周期内逐日序列（旧 → 新，最后一项为今日）：
    /// 今日周期 = 近 7 日；本周/本月 = 周期起点至今日（已用天数）。
    var daily: [DayPoint]
    /// 峰值日（并列取最早；无正数 → nil）。
    var peak: DayPoint?
}

/// 从半小时桶构建周期化用量快照 — 纯函数。
///
/// `period == .today` 时保持既有语义：序列为近 7 日（今日起往前 6 天）；
/// `week / month` 时按周期窗口过滤，序列为窗口起点至今日的逐日总和。
enum UsageOverviewBuilder {
    static let trendDays = 7

    static func make(
        buckets: [UsageBucketState],
        now: Date,
        calendar: Calendar,
        period: TokenUsagePeriod = .today
    ) -> TokenUsageOverview? {
        switch period {
        case .today:
            return makeToday(buckets: buckets, now: now, calendar: calendar)
        case .week, .month:
            return makePeriod(buckets: buckets, now: now, calendar: calendar, period: period)
        }
    }

    /// 今日周期：近 7 日趋势 + 今日总计（#04 既有语义）。
    private static func makeToday(
        buckets: [UsageBucketState],
        now: Date,
        calendar: Calendar
    ) -> TokenUsageOverview? {
        let todayStart = calendar.startOfDay(for: now)
        guard let weekStart = calendar.date(byAdding: .day, value: -(trendDays - 1), to: todayStart) else {
            return nil
        }
        let inWindow = buckets.filter { $0.key.bucketStart >= weekStart }
        guard !inWindow.isEmpty else { return nil }

        let dayTotals = dayTotals(inWindow, calendar: calendar)

        let points: [TokenUsageOverview.DayPoint] = (0..<trendDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return TokenUsageOverview.DayPoint(dayStart: day, totalTokens: dayTotals[day] ?? 0)
        }
        guard points.count == trendDays else { return nil }

        let todayConversations = inWindow
            .filter { calendar.isDate($0.key.bucketStart, inSameDayAs: todayStart) }
            .reduce(0) { $0 + $1.conversationCount }

        return TokenUsageOverview(
            totalTokens: dayTotals[todayStart] ?? 0,
            conversations: todayConversations,
            daily: points,
            peak: peak(in: points)
        )
    }

    /// 本周 / 本月周期：窗口内过滤 + 周期起点至今日的逐日序列。
    private static func makePeriod(
        buckets: [UsageBucketState],
        now: Date,
        calendar: Calendar,
        period: TokenUsagePeriod
    ) -> TokenUsageOverview? {
        guard let window = UsagePeriodWindow.window(for: period, now: now, calendar: calendar) else {
            return nil
        }
        let inWindow = buckets.filter {
            $0.key.bucketStart >= window.start && $0.key.bucketStart < window.end
        }
        guard !inWindow.isEmpty else { return nil }

        let dayTotals = dayTotals(inWindow, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)
        var points: [TokenUsageOverview.DayPoint] = []
        var day = UsagePeriodWindow.seriesStart(for: window, calendar: calendar)
        while day <= todayStart {
            points.append(TokenUsageOverview.DayPoint(dayStart: day, totalTokens: dayTotals[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !points.isEmpty else { return nil }

        return TokenUsageOverview(
            totalTokens: inWindow.reduce(0) { $0 + $1.usage.totalTokens },
            conversations: inWindow.reduce(0) { $0 + $1.conversationCount },
            daily: points,
            peak: peak(in: points)
        )
    }

    private static func dayTotals(
        _ states: [UsageBucketState],
        calendar: Calendar
    ) -> [Date: Int] {
        var totals: [Date: Int] = [:]
        for state in states {
            let day = calendar.startOfDay(for: state.key.bucketStart)
            totals[day, default: 0] += state.usage.totalTokens
        }
        return totals
    }

    private static func peak(in points: [TokenUsageOverview.DayPoint]) -> TokenUsageOverview.DayPoint? {
        var peak: TokenUsageOverview.DayPoint?
        var peakTotal = 0
        for point in points where point.totalTokens > peakTotal {
            peakTotal = point.totalTokens
            peak = point
        }
        return peak
    }
}
