import Foundation

/// Token 仪表盘快照构建器：一次读齐存储并算齐全部趋势周期。
///
/// 纯同步实现，可脱离主线程执行（`UsageStoring` 的实现是串行队列数据库，
/// 跨线程调用安全）；主线程只在结果赋值时参与。
enum TokenUsageDashboardSnapshotBuilder {
    /// 全周期仪表盘快照：面板渲染的单一数据源（SPEC §9.2.3）。
    static func make(
        daily: [UsageDayProviderAggregate],
        store: UsageStoring?,
        now: Date,
        calendar: Calendar = .current
    ) -> TokenUsageDashboardSnapshot {
        var trendPoints: [TokenTrendPeriod: [UsageTrendPoint]] = [:]
        var topModels: [TokenTrendPeriod: [UsageTopModelEntry]] = [:]
        for period in TokenTrendPeriod.allCases {
            trendPoints[period] = self.trendPoints(
                filteredBy: nil,
                period: period,
                daily: daily,
                store: store,
                now: now,
                calendar: calendar
            )
            topModels[period] = self.topModels(
                filteredBy: nil,
                period: period,
                store: store,
                now: now,
                calendar: calendar
            )
        }
        return TokenUsageDashboardSnapshot(
            summaryCards: summaryCards(filteredBy: nil, daily: daily, now: now, calendar: calendar),
            heatmap: heatmap(filteredBy: nil, daily: daily, now: now, calendar: calendar),
            trendPoints: trendPoints,
            topModels: topModels,
            updatedAt: now
        )
    }

    // MARK: - 单项查询（与既有面板语义一致）

    static func summaryCards(
        filteredBy provider: TokenUsageProvider?,
        daily: [UsageDayProviderAggregate],
        now: Date,
        calendar: Calendar
    ) -> UsageSummaryCards {
        let filtered = dailyAggregates(daily, filteredBy: provider)
        return UsageSummaryCardsBuilder.make(daily: filtered, now: now, calendar: calendar)
    }

    static func heatmap(
        filteredBy provider: TokenUsageProvider?,
        daily: [UsageDayProviderAggregate],
        now: Date,
        calendar: Calendar
    ) -> UsageActivityHeatmap? {
        let filtered = dailyAggregates(daily, filteredBy: provider)
        return UsageHeatmapBuilder.make(daily: filtered, now: now, calendar: calendar)
    }

    static func trendPoints(
        filteredBy provider: TokenUsageProvider?,
        period: TokenTrendPeriod,
        daily: [UsageDayProviderAggregate],
        store: UsageStoring?,
        now: Date,
        calendar: Calendar
    ) -> [UsageTrendPoint] {
        let filtered = dailyAggregates(daily, filteredBy: provider)
        let hourly = period == .day
            ? todayBuckets(filteredBy: provider, store: store, now: now, calendar: calendar)
            : []
        return UsageTrendBuilder.make(
            period: period,
            daily: filtered,
            hourlyBuckets: hourly,
            now: now,
            calendar: calendar
        )
    }

    static func topModels(
        filteredBy provider: TokenUsageProvider?,
        period: TokenTrendPeriod,
        store: UsageStoring?,
        now: Date,
        calendar: Calendar
    ) -> [UsageTopModelEntry] {
        guard let store else { return [] }
        let window = modelWindow(period: period, now: now, calendar: calendar)
        let providers = provider.map { Set([$0]) }
        let aggregates = store.loadModelAggregates(
            from: window.start,
            to: window.end,
            providers: providers
        )
        return UsageTopModelsBuilder.make(models: aggregates)
    }

    // MARK: - 共享查询原语

    private static func dailyAggregates(
        _ daily: [UsageDayProviderAggregate],
        filteredBy provider: TokenUsageProvider?
    ) -> [UsageDayProviderAggregate] {
        guard let provider else { return daily }
        return daily.filter { $0.provider == provider }
    }

    private static func todayBuckets(
        filteredBy provider: TokenUsageProvider?,
        store: UsageStoring?,
        now: Date,
        calendar: Calendar
    ) -> [UsageBucketState] {
        guard let store else { return [] }
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? now.addingTimeInterval(86_400)
        let providers = provider.map { Set([$0]) }
        return store.loadBuckets(from: todayStart, to: tomorrow, providers: providers)
    }

    /// 模型统计窗口：日=今日；周=近 7 日；月=近 30 日；总计=全历史。
    static func modelWindow(
        period: TokenTrendPeriod,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? now.addingTimeInterval(86_400)
        switch period {
        case .day:
            return (todayStart, tomorrow)
        case .week:
            let start = calendar.date(
                byAdding: .day, value: -(UsageSummaryCardsBuilder.sevenDays - 1), to: todayStart
            ) ?? todayStart
            return (start, tomorrow)
        case .month:
            let start = calendar.date(
                byAdding: .day, value: -(UsageSummaryCardsBuilder.thirtyDays - 1), to: todayStart
            ) ?? todayStart
            return (start, tomorrow)
        case .total:
            return (Date(timeIntervalSince1970: 0), tomorrow)
        }
    }
}
