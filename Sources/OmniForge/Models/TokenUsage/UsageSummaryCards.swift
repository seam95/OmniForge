import Foundation

// MARK: - 汇总卡快照

/// 顶部 4 张汇总卡的数据快照（今日 / 7天 / 30天 / 总计）。
///
/// 副标口径（SPEC 2.1，无成本数据）：今日 = 会话数；7天 = 活跃日；
/// 30天 = 平均每活跃日；总计 = 全部活跃日。
struct UsageSummaryCards: Equatable {
    var todayTokens: Int
    var todayConversations: Int
    var last7dTokens: Int
    var last7dActiveDays: Int
    var last30dTokens: Int
    var last30dAvgPerActiveDay: Int
    var totalTokens: Int
    var totalActiveDays: Int

    static let zero = UsageSummaryCards(
        todayTokens: 0,
        todayConversations: 0,
        last7dTokens: 0,
        last7dActiveDays: 0,
        last30dTokens: 0,
        last30dAvgPerActiveDay: 0,
        totalTokens: 0,
        totalActiveDays: 0
    )
}

// MARK: - 汇总卡构建器

/// 从日聚合（已按 provider 过滤）派生 4 张汇总卡 — 纯函数。
///
/// 窗口语义：近 7 日 = 含今日往前 6 天；近 30 日 = 含今日往前 29 天；
/// 活跃日 = 窗口内 totalTokens > 0 的本地日；平均 = 30 日总量 / 30 日活跃日。
enum UsageSummaryCardsBuilder {
    static let sevenDays = 7
    static let thirtyDays = 30

    static func make(
        daily: [UsageDayProviderAggregate],
        now: Date,
        calendar: Calendar
    ) -> UsageSummaryCards {
        let todayStart = calendar.startOfDay(for: now)
        let byDay = daily.mergedByDay
        guard !byDay.isEmpty else { return .zero }

        let todayTokens = byDay[todayStart]?.totalTokens ?? 0
        let todayConversations = byDay[todayStart]?.conversations ?? 0

        let sevenStart = calendar.date(byAdding: .day, value: -(sevenDays - 1), to: todayStart) ?? todayStart
        let thirtyStart = calendar.date(byAdding: .day, value: -(thirtyDays - 1), to: todayStart) ?? todayStart

        let sevenDay = window(byDay, from: sevenStart, through: todayStart)
        let thirtyDay = window(byDay, from: thirtyStart, through: todayStart)

        let totalTokens = byDay.values.reduce(0) { $0 + $1.totalTokens }
        let totalActiveDays = byDay.values.filter { $0.totalTokens > 0 }.count

        let last30dActiveDays = thirtyDay.filter { $0.value.totalTokens > 0 }.count
        let avg = last30dActiveDays > 0
            ? thirtyDay.values.reduce(0) { $0 + $1.totalTokens } / last30dActiveDays
            : 0

        return UsageSummaryCards(
            todayTokens: todayTokens,
            todayConversations: todayConversations,
            last7dTokens: sevenDay.values.reduce(0) { $0 + $1.totalTokens },
            last7dActiveDays: sevenDay.filter { $0.value.totalTokens > 0 }.count,
            last30dTokens: thirtyDay.values.reduce(0) { $0 + $1.totalTokens },
            last30dAvgPerActiveDay: avg,
            totalTokens: totalTokens,
            totalActiveDays: totalActiveDays
        )
    }

    private static func window(
        _ byDay: [Date: (totalTokens: Int, conversations: Int)],
        from start: Date,
        through end: Date
    ) -> [Date: (totalTokens: Int, conversations: Int)] {
        byDay.filter { $0.key >= start && $0.key <= end }
    }
}
