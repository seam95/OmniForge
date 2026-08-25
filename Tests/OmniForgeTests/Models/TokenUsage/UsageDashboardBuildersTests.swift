import XCTest
@testable import OmniForge

/// 仪表盘构建器纯函数单测：汇总卡 / 热力图 / 趋势 / 模型 Top（2026-08-25 重设计）。
/// 使用固定 UTC 日历保证日界/周界确定。
final class UsageDashboardBuildersTests: XCTestCase {

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 构造 UTC 日历下的本地日（默认 0 点，与构建器日界/月界对齐）。
    private func day(_ year: Int, _ month: Int, _ d: Int, calendar: Calendar, hour: Int = 0) -> Date {
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = d
        comps.hour = hour
        return calendar.date(from: comps)!
    }

    private func aggregate(_ dayStart: Date, total: Int, conversations: Int = 0, provider: TokenUsageProvider = .claude) -> UsageDayProviderAggregate {
        UsageDayProviderAggregate(
            dayStart: dayStart,
            provider: provider,
            totalTokens: total,
            conversations: conversations
        )
    }

    private func bucket(at date: Date, total: Int) -> UsageBucketState {
        UsageBucketState(
            key: UsageBucketKey(provider: .claude, model: "m", bucketStart: date),
            usage: TokenUsage(inputTokens: total, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total),
            conversationCount: 0
        )
    }

    // MARK: - 汇总卡

    func test_summaryCards_windowsAndActiveDays() {
        let calendar = utcCalendar()
        let now = day(2026, 8, 25, calendar: calendar)
        let daily = [
            aggregate(day(2026, 8, 25, calendar: calendar), total: 100, conversations: 3),
            aggregate(day(2026, 8, 23, calendar: calendar), total: 200, conversations: 1),
            aggregate(day(2026, 7, 16, calendar: calendar), total: 400),
        ]
        let cards = UsageSummaryCardsBuilder.make(daily: daily, now: now, calendar: calendar)
        XCTAssertEqual(cards.todayTokens, 100)
        XCTAssertEqual(cards.todayConversations, 3)
        XCTAssertEqual(cards.last7dTokens, 300)
        XCTAssertEqual(cards.last7dActiveDays, 2)
        XCTAssertEqual(cards.last30dTokens, 300, "7/16 在 30 日窗口外")
        XCTAssertEqual(cards.last30dAvgPerActiveDay, 150)
        XCTAssertEqual(cards.totalTokens, 700)
        XCTAssertEqual(cards.totalActiveDays, 3)
    }

    func test_summaryCards_mergesProvidersPerDay() {
        let calendar = utcCalendar()
        let now = day(2026, 8, 25, calendar: calendar)
        let daily = [
            aggregate(day(2026, 8, 25, calendar: calendar), total: 100, provider: .claude),
            aggregate(day(2026, 8, 25, calendar: calendar), total: 50, provider: .codex),
        ]
        let cards = UsageSummaryCardsBuilder.make(daily: daily, now: now, calendar: calendar)
        XCTAssertEqual(cards.todayTokens, 150)
        XCTAssertEqual(cards.totalActiveDays, 1, "同日两家合并为一个活跃日")
    }

    func test_summaryCards_emptyReturnsZero() {
        let calendar = utcCalendar()
        let cards = UsageSummaryCardsBuilder.make(daily: [], now: day(2026, 8, 25, calendar: calendar), calendar: calendar)
        XCTAssertEqual(cards, .zero)
    }

    // MARK: - 活跃度热力图

    func test_heatmap_builds53WeeksEndingThisWeek() {
        let calendar = utcCalendar()
        let now = day(2026, 8, 25, calendar: calendar) // 周二
        let daily = [
            aggregate(day(2026, 8, 25, calendar: calendar), total: 50),
            aggregate(day(2026, 8, 24, calendar: calendar), total: 150),
        ]
        let heatmap = UsageHeatmapBuilder.make(daily: daily, now: now, calendar: calendar, weekCount: 53)
        XCTAssertNotNil(heatmap)
        XCTAssertEqual(heatmap?.weeks.count, 53)
        XCTAssertEqual(heatmap?.activeDays, 2)

        let todayCell = heatmap?.weeks.flatMap { $0 }.compactMap { $0 }
            .first { $0.dayStart == day(2026, 8, 25, calendar: calendar) }
        XCTAssertEqual(todayCell?.totalTokens, 50)
        XCTAssertEqual(todayCell?.level, 2, "50/150 → ceil(0.333*4) = 2")
    }

    func test_heatmap_levelBands() {
        XCTAssertEqual(UsageHeatmapBuilder.level(for: 0, maxTokens: 100), 0)
        XCTAssertEqual(UsageHeatmapBuilder.level(for: 1, maxTokens: 100), 1, "任何正数至少 1 档")
        XCTAssertEqual(UsageHeatmapBuilder.level(for: 100, maxTokens: 100), 4)
        XCTAssertEqual(UsageHeatmapBuilder.level(for: 30, maxTokens: 100), 2, "ceil(1.2) = 2")
        XCTAssertEqual(UsageHeatmapBuilder.level(for: 80, maxTokens: 100), 4, "ceil(3.2) = 4 上限")
    }

    func test_heatmap_emptyReturnsNil() {
        let calendar = utcCalendar()
        XCTAssertNil(UsageHeatmapBuilder.make(daily: [], now: day(2026, 8, 25, calendar: calendar), calendar: calendar))
    }

    // MARK: - 趋势

    func test_trend_day_aggregatesByHourUpToNow() {
        let calendar = utcCalendar()
        let now = day(2026, 8, 25, calendar: calendar, hour: 10) // 10:00 UTC
        let todayStart = calendar.startOfDay(for: now)
        let buckets = [
            bucket(at: todayStart.addingTimeInterval(1 * 3600 + 120), total: 100),
            bucket(at: todayStart.addingTimeInterval(1 * 3600 + 900), total: 200),
            bucket(at: todayStart.addingTimeInterval(3 * 3600), total: 50),
        ]
        let points = UsageTrendBuilder.make(period: .day, daily: [], hourlyBuckets: buckets, now: now, calendar: calendar)
        XCTAssertEqual(points.count, 11, "0...10 小时共 11 点")
        XCTAssertEqual(points[1].tokens, 300, "同一小时两桶求和")
        XCTAssertEqual(points[3].tokens, 50)
        XCTAssertEqual(points[10].tokens, 0, "无数据小时补零")
    }

    func test_trend_day_emptyReturnsEmpty() {
        let calendar = utcCalendar()
        XCTAssertTrue(
            UsageTrendBuilder.make(period: .day, daily: [], hourlyBuckets: [], now: day(2026, 8, 25, calendar: calendar), calendar: calendar).isEmpty
        )
    }

    func test_trend_weekAndMonth_fillDailyZeros() {
        let calendar = utcCalendar()
        let now = day(2026, 8, 25, calendar: calendar)
        let daily = [
            aggregate(day(2026, 8, 25, calendar: calendar), total: 100),
            aggregate(day(2026, 8, 20, calendar: calendar), total: 50),
        ]
        let week = UsageTrendBuilder.make(period: .week, daily: daily, hourlyBuckets: [], now: now, calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.reduce(0) { $0 + $1.tokens }, 150)
        XCTAssertEqual(week.last?.date, day(2026, 8, 25, calendar: calendar))
        XCTAssertEqual(week.first?.tokens, 0, "窗口起点无数据补零")

        let month = UsageTrendBuilder.make(period: .month, daily: daily, hourlyBuckets: [], now: now, calendar: calendar)
        XCTAssertEqual(month.count, 30)
        XCTAssertEqual(month.reduce(0) { $0 + $1.tokens }, 150)
    }

    func test_trend_total_groupsByMonthAndCapsWindow() {
        let calendar = utcCalendar()
        let now = day(2026, 8, 25, calendar: calendar)
        let daily = [
            aggregate(day(2026, 8, 25, calendar: calendar), total: 100),
            aggregate(day(2026, 8, 1, calendar: calendar), total: 50),
            aggregate(day(2026, 7, 1, calendar: calendar), total: 300),
            aggregate(day(2025, 9, 1, calendar: calendar), total: 700),
            aggregate(day(2023, 1, 1, calendar: calendar), total: 999),
        ]
        let total = UsageTrendBuilder.make(period: .total, daily: daily, hourlyBuckets: [], now: now, calendar: calendar)
        XCTAssertEqual(total.count, 24, "近 24 个月窗口 2024-09...2026-08")
        XCTAssertEqual(total.first?.date, day(2024, 9, 1, calendar: calendar))
        XCTAssertEqual(total.reduce(0) { $0 + $1.tokens }, 1150, "2023 年数据被窗口截断")
        XCTAssertEqual(total.last?.tokens, 150, "2026-08 两日合并")
    }

    func test_trend_total_emptyReturnsEmpty() {
        let calendar = utcCalendar()
        XCTAssertTrue(
            UsageTrendBuilder.make(period: .total, daily: [], hourlyBuckets: [], now: day(2026, 8, 25, calendar: calendar), calendar: calendar).isEmpty
        )
    }

    // MARK: - 模型 Top

    func test_topModels_percentSortAndLimit() {
        let models = [
            UsageModelAggregate(model: "a", totalTokens: 100),
            UsageModelAggregate(model: "b", totalTokens: 300),
            UsageModelAggregate(model: "c", totalTokens: 0),
            UsageModelAggregate(model: "d", totalTokens: 100),
            UsageModelAggregate(model: "e", totalTokens: 200),
            UsageModelAggregate(model: "f", totalTokens: 300),
        ]
        let top = UsageTopModelsBuilder.make(models: models, limit: 5)
        XCTAssertEqual(top.map(\.name), ["b", "f", "e", "a", "d"], "降序、同名字典序、剔除 0")
        XCTAssertEqual(top.map(\.tokens), [300, 300, 200, 100, 100])
        XCTAssertEqual(top[0].percent, 30.0, accuracy: 0.001)
        XCTAssertEqual(top[1].percent, 30.0, accuracy: 0.001)
        XCTAssertEqual(top[2].percent, 20.0, accuracy: 0.001)
    }

    func test_topModels_emptyAndAllZero() {
        XCTAssertTrue(UsageTopModelsBuilder.make(models: []).isEmpty)
        XCTAssertTrue(UsageTopModelsBuilder.make(models: [UsageModelAggregate(model: "x", totalTokens: 0)]).isEmpty)
    }
}
