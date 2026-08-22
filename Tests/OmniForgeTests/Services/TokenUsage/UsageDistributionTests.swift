import XCTest
@testable import OmniForge

/// 用量分布（按模型 / 按 Provider）与周期窗口（今日/本周/本月）— 纯函数（SPEC 8）。
///
/// 固定时钟：2026-08-22（周六）14:00 Asia/Shanghai；纯 `Calendar(identifier:)`
/// 的 firstWeekday = 1（周日），因此本周窗口 = 8-16（周日）~ 8-23（周日），
/// 本月窗口 = 8-01 ~ 9-01。
final class UsageDistributionTests: XCTestCase {

    private var fixtureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private var now: Date {
        fixtureCalendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 14))!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        fixtureCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func dayFromNow(_ offset: Int) -> Date {
        let base = fixtureCalendar.startOfDay(for: now)
        return fixtureCalendar.date(byAdding: .day, value: offset, to: base)!
    }

    private func bucket(
        at date: Date,
        provider: TokenUsageProvider = .claude,
        model: String = "claude-opus-4-5",
        total: Int,
        conversations: Int = 0
    ) -> UsageBucketState {
        UsageBucketState(
            key: UsageBucketKey(provider: provider, model: model, bucketStart: date),
            usage: TokenUsage(
                inputTokens: total,
                cachedInputTokens: 0,
                cacheCreationInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: total
            ),
            conversationCount: conversations
        )
    }

    // MARK: - 周期窗口

    func test_periodWindow_today_goesFromMidnightToTomorrow() throws {
        let window = try XCTUnwrap(UsagePeriodWindow.window(for: .today, now: now, calendar: fixtureCalendar))
        XCTAssertEqual(window.start, day(2026, 8, 22))
        XCTAssertEqual(window.end, day(2026, 8, 23))
    }

    func test_periodWindow_week_coversCurrentWeekUpToNextWeekStart() throws {
        let window = try XCTUnwrap(UsagePeriodWindow.window(for: .week, now: now, calendar: fixtureCalendar))
        // firstWeekday = 1（周日）→ 本周 = 8-16（周日）起
        XCTAssertEqual(window.start, day(2026, 8, 16))
        XCTAssertEqual(window.end, day(2026, 8, 23))
    }

    func test_periodWindow_month_coversMonthInterval() throws {
        let window = try XCTUnwrap(UsagePeriodWindow.window(for: .month, now: now, calendar: fixtureCalendar))
        XCTAssertEqual(window.start, day(2026, 8, 1))
        XCTAssertEqual(window.end, day(2026, 9, 1))
    }

    // MARK: - 分布聚合

    func test_distribution_groupsByModelSortedDescending() throws {
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 22, hour: 10), model: "opus-4.8", total: 84_200),
                bucket(at: day(2026, 8, 22, hour: 11), model: "sonnet-4.5", total: 32_100),
                bucket(at: day(2026, 8, 22, hour: 12), model: "haiku-4.5", total: 12_100),
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .today
        ))
        XCTAssertEqual(distribution.byModel, [
            UsageDistributionEntry(label: "opus-4.8", totalTokens: 84_200),
            UsageDistributionEntry(label: "sonnet-4.5", totalTokens: 32_100),
            UsageDistributionEntry(label: "haiku-4.5", totalTokens: 12_100),
        ])
    }

    func test_distribution_groupsByProviderAcrossModels() throws {
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 22, hour: 10), provider: .claude, model: "opus", total: 84_200),
                bucket(at: day(2026, 8, 22, hour: 11), provider: .claude, model: "sonnet", total: 12_200),
                bucket(at: day(2026, 8, 22, hour: 12), provider: .codex, model: "gpt-5", total: 24_800),
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .today
        ))
        XCTAssertEqual(distribution.byProvider, [
            UsageDistributionEntry(label: "Claude", totalTokens: 96_400, provider: .claude),
            UsageDistributionEntry(label: "Codex", totalTokens: 24_800, provider: .codex),
        ])
        XCTAssertEqual(distribution.byModel, [
            UsageDistributionEntry(label: "opus", totalTokens: 84_200),
            UsageDistributionEntry(label: "gpt-5", totalTokens: 24_800),
            UsageDistributionEntry(label: "sonnet", totalTokens: 12_200),
        ])
    }

    func test_distribution_filtersToSelectedPeriodWindow() throws {
        let buckets = [
            bucket(at: day(2026, 8, 22, hour: 10), total: 10_000),
            bucket(at: day(2026, 8, 20, hour: 9), total: 5_000),   // 本周内，月内
            bucket(at: day(2026, 8, 2, hour: 9), total: 3_000),    // 月内，本周外
            bucket(at: day(2026, 7, 20, hour: 9), total: 99_000),  // 均不在窗口
        ]
        let today = try XCTUnwrap(UsageDistributionBuilder.make(buckets: buckets, now: now, calendar: fixtureCalendar, period: .today))
        XCTAssertEqual(today.byModel.map(\.totalTokens), [10_000])

        let week = try XCTUnwrap(UsageDistributionBuilder.make(buckets: buckets, now: now, calendar: fixtureCalendar, period: .week))
        XCTAssertEqual(week.byModel.map(\.totalTokens), [15_000])

        let month = try XCTUnwrap(UsageDistributionBuilder.make(buckets: buckets, now: now, calendar: fixtureCalendar, period: .month))
        XCTAssertEqual(month.byModel.map(\.totalTokens), [18_000])
    }

    func test_distribution_sortedTiesBrokenDeterministically() throws {
        // 并列总量：模型按名字典序（"b" < "g"）；provider 按目录序（gemini 先于 kimi）。
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 20, hour: 9), provider: .gemini, model: "g-2", total: 50),
                bucket(at: day(2026, 8, 20, hour: 10), provider: .kimi, model: "b-2", total: 50),
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .week
        ))
        XCTAssertEqual(distribution.byModel.map(\.label), ["b-2", "g-2"], "模型行总量并列时按名字典序")
        XCTAssertEqual(distribution.byProvider.map(\.provider), [.gemini, .kimi], "provider 行总量并列时按目录序")
    }

    func test_distribution_emptyWindowReturnsNil() {
        XCTAssertNil(UsageDistributionBuilder.make(
            buckets: [bucket(at: day(2026, 7, 20, hour: 9), total: 99_000)],
            now: now,
            calendar: fixtureCalendar,
            period: .today
        ))
    }

    // MARK: - Cursor 云端口径占位行（#09：无本地日志；无数值时右值灰显 "--"）

    func test_distribution_cursorConfiguredNoData_appendsPlaceholderRowWithNilValue() throws {
        // 窗口内只有 Claude 数据：Cursor 已配置但无数据 → 追加占位行（nil totalTokens），
        // 且排在数据行之后（保持数据行在前）。
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [bucket(at: day(2026, 8, 22, hour: 10), provider: .claude, total: 96_400)],
            now: now,
            calendar: fixtureCalendar,
            period: .today,
            configuredProviders: [.claude, .cursor]
        ))
        XCTAssertEqual(distribution.byProvider, [
            UsageDistributionEntry(label: "Claude", totalTokens: 96_400, provider: .claude),
            UsageDistributionEntry(label: "Cursor", totalTokens: nil, provider: .cursor),
        ])
    }

    func test_distribution_cursorWithData_noPlaceholderRow() throws {
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 22, hour: 10), provider: .cursor, model: "auto", total: 41_000),
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .today,
            configuredProviders: [.cursor]
        ))
        XCTAssertEqual(distribution.byProvider.count, 1)
        XCTAssertEqual(distribution.byProvider.first?.totalTokens, 41_000, "有数据则显示真实值，不出占位行")
    }

    func test_distribution_cursorNotConfigured_noPlaceholderRow() throws {
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [bucket(at: day(2026, 8, 22, hour: 10), provider: .claude, total: 96_400)],
            now: now,
            calendar: fixtureCalendar,
            period: .today,
            configuredProviders: [.claude]
        ))
        XCTAssertEqual(distribution.byProvider.count, 1, "未配置 → 不出现 Cursor 行")
    }

    func test_distribution_placeholderOnlyForCursor_notOtherProviders() throws {
        // 未来 provider 无数据仍不出现占位行（占位语义是 Cursor 云端口径专属）。
        let distribution = try XCTUnwrap(UsageDistributionBuilder.make(
            buckets: [bucket(at: day(2026, 8, 22, hour: 10), provider: .claude, total: 96_400)],
            now: now,
            calendar: fixtureCalendar,
            period: .today,
            configuredProviders: [.claude, .codex]
        ))
        XCTAssertEqual(distribution.byProvider.count, 1, "非 Cursor provider 无数据不出现")
    }

    func test_distribution_windowStillEmptyWithoutAnyData_returnsNil() {
        // 空窗口（无任何 provider 数据）→ 整块隐藏规则优先（SPEC 4.3），不单独渲 Cursor 占位。
        XCTAssertNil(UsageDistributionBuilder.make(
            buckets: [],
            now: now,
            calendar: fixtureCalendar,
            period: .today,
            configuredProviders: [.cursor]
        ))
    }

    // MARK: - 周期化用量快照（周/月重算）

    func test_builder_periodToday_keepsSevenDayTrend() throws {
        let overview = try XCTUnwrap(UsageOverviewBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 22, hour: 10), total: 128_000, conversations: 3),
                bucket(at: day(2026, 8, 21, hour: 10), total: 168_000, conversations: 5),
                bucket(at: day(2026, 8, 16, hour: 10), total: 10_000, conversations: 1),
                bucket(at: day(2026, 8, 14, hour: 10), total: 9_000, conversations: 0), // 7 日窗口外
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .today
        ))
        XCTAssertEqual(overview.totalTokens, 128_000, "今日快照大数值只算今日")
        XCTAssertEqual(overview.conversations, 3)
        XCTAssertEqual(overview.daily.count, 7, "今日周期仍为近 7 日趋势")
        XCTAssertEqual(overview.daily.first?.dayStart, day(2026, 8, 16))
        XCTAssertEqual(overview.daily.last?.totalTokens, 128_000, "序列最后一项为今日")
        XCTAssertEqual(overview.daily.map(\.totalTokens).reduce(0, +), 306_000, "序列含 7 日全部数据")
        XCTAssertEqual(overview.peak?.totalTokens, 168_000, "峰值来自历史日")
    }

    func test_builder_periodWeek_aggregatesWeekWindow() throws {
        let overview = try XCTUnwrap(UsageOverviewBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 22, hour: 10), total: 50_000, conversations: 3),
                bucket(at: day(2026, 8, 17, hour: 10), total: 30_000, conversations: 1),
                bucket(at: day(2026, 8, 15, hour: 10), total: 20_000, conversations: 2), // 上周末，窗口外（周日起算）
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .week
        ))
        XCTAssertEqual(overview.totalTokens, 80_000, "本周总量 = 今日 + 本周内历史")
        XCTAssertEqual(overview.conversations, 4)
        XCTAssertEqual(overview.daily.count, 7, "周日（8-16）→ 周六（8-22）共 7 天")
        XCTAssertEqual(overview.daily.first?.dayStart, day(2026, 8, 16))
        XCTAssertEqual(overview.daily.last?.dayStart, day(2026, 8, 22))
        XCTAssertEqual(overview.daily[1].totalTokens, 30_000, "8-17 与 8-15 桶合并后仅本周内的计入")
        XCTAssertEqual(overview.peak?.totalTokens, 50_000, "本周峰值来自今日")
    }

    func test_builder_periodMonth_aggregatesMonthWindow() throws {
        let overview = try XCTUnwrap(UsageOverviewBuilder.make(
            buckets: [
                bucket(at: day(2026, 8, 2, hour: 9), total: 10_000, conversations: 1),
                bucket(at: day(2026, 8, 22, hour: 10), total: 5_000, conversations: 2),
                bucket(at: day(2026, 7, 20, hour: 9), total: 99_000, conversations: 9), // 上月，窗口外
            ],
            now: now,
            calendar: fixtureCalendar,
            period: .month
        ))
        XCTAssertEqual(overview.totalTokens, 15_000, "本月总量 = 本月内全部桶")
        XCTAssertEqual(overview.conversations, 3)
        XCTAssertEqual(overview.daily.count, 22, "8-01 → 8-22 逐日")
        XCTAssertEqual(overview.daily.first?.dayStart, day(2026, 8, 1))
        XCTAssertEqual(overview.daily.last?.dayStart, day(2026, 8, 22))
        XCTAssertEqual(overview.peak?.totalTokens, 10_000)
        XCTAssertEqual(overview.peak?.dayStart, day(2026, 8, 2))
    }

    func test_builder_periodWeek_emptyWindowReturnsNil() {
        XCTAssertNil(UsageOverviewBuilder.make(
            buckets: [bucket(at: day(2026, 7, 20, hour: 9), total: 99_000)],
            now: now,
            calendar: fixtureCalendar,
            period: .week
        ))
    }
}
