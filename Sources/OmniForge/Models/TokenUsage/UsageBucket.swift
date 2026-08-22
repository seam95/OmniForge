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

/// 今日用量卡快照（聚合若干 provider 后可复用）。
struct TokenUsageOverview: Equatable {
    struct DayPoint: Equatable {
        var dayStart: Date
        var totalTokens: Int
    }

    var todayTotalTokens: Int
    var todayConversations: Int
    /// 近 7 日（旧 → 新，最后一项为今日）。
    var sevenDay: [DayPoint]
    /// 峰值日（并列取最早；无正数 → nil）。
    var peak: DayPoint?
}

/// 从半小时桶构建面板快照 — 纯函数。窗口 = 今日起往前 6 天（共 7 日）。
enum UsageOverviewBuilder {
    static let trendDays = 7

    static func make(
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

        var dayTotals: [Date: Int] = [:]
        for state in inWindow {
            let day = calendar.startOfDay(for: state.key.bucketStart)
            dayTotals[day, default: 0] += state.usage.totalTokens
        }

        let points: [TokenUsageOverview.DayPoint] = (0..<trendDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return TokenUsageOverview.DayPoint(dayStart: day, totalTokens: dayTotals[day] ?? 0)
        }
        guard points.count == trendDays else { return nil }

        var peak: TokenUsageOverview.DayPoint?
        var peakTotal = 0
        for point in points where point.totalTokens > peakTotal {
            peakTotal = point.totalTokens
            peak = point
        }

        let todayConversations = inWindow
            .filter { calendar.isDate($0.key.bucketStart, inSameDayAs: todayStart) }
            .reduce(0) { $0 + $1.conversationCount }

        return TokenUsageOverview(
            todayTotalTokens: dayTotals[todayStart] ?? 0,
            todayConversations: todayConversations,
            sevenDay: points,
            peak: peak
        )
    }
}
