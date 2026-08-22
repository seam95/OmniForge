import XCTest
@testable import OmniForge

/// 半小时桶聚合：从既有累计 seed、累加、touched 快照 — 幂等 upsert 纯逻辑（参考 02）。
final class UsageAggregatorTests: XCTestCase {

    private let provider: TokenUsageProvider = .claude
    private let bucketStart = Date(timeIntervalSince1970: 1_784_700_000)
    private let delta = TokenUsage(
        inputTokens: 100,
        cachedInputTokens: 30,
        cacheCreationInputTokens: 20,
        outputTokens: 10,
        reasoningOutputTokens: 0,
        totalTokens: 160
    )

    private func key(model: String = "claude-sonnet-4-5") -> UsageBucketKey {
        UsageBucketKey(provider: provider, model: model, bucketStart: bucketStart)
    }

    func test_ingest_accumulatesTokensAndConversations() {
        let aggregator = UsageAggregator()
        aggregator.ingest(usage: delta, conversationDelta: 1, key: key())
        aggregator.ingest(usage: delta, conversationDelta: 0, key: key())
        let drained = aggregator.drainTouched()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].usage.totalTokens, 320)
        XCTAssertEqual(drained[0].usage.inputTokens, 200)
        XCTAssertEqual(drained[0].conversationCount, 1)
        XCTAssertTrue(aggregator.drainTouched().isEmpty, "drain 后清空")
    }

    func test_ingest_seedsFromStoredCumulative() {
        let existing = UsageBucketState(
            key: key(),
            usage: TokenUsage(
                inputTokens: 50,
                cachedInputTokens: 0,
                cacheCreationInputTokens: 0,
                outputTokens: 5,
                reasoningOutputTokens: 0,
                totalTokens: 55
            ),
            conversationCount: 2
        )
        let aggregator = UsageAggregator { _ in existing }
        aggregator.ingest(usage: delta, conversationDelta: 1, key: key())
        let drained = aggregator.drainTouched()
        XCTAssertEqual(drained[0].usage.totalTokens, 215, "DB 累计 + 本次增量")
        XCTAssertEqual(drained[0].conversationCount, 3)
    }

    func test_ingest_separatesBucketsByModelAndBucket() {
        let aggregator = UsageAggregator()
        aggregator.ingest(usage: delta, conversationDelta: 0, key: key(model: "a"))
        aggregator.ingest(usage: delta, conversationDelta: 0, key: key(model: "b"))
        aggregator.ingest(usage: delta, conversationDelta: 0, key: UsageBucketKey(
            provider: .codex, model: "a", bucketStart: bucketStart
        ))
        XCTAssertEqual(aggregator.drainTouched().count, 3)
    }

    func test_cumulativeState_writtenAndSeeded_replaysCorrectly() {
        // 幂等回环：写下累计快照 → 重新 seed → 无新增量时 touched 为空（不重复写）；
        // 有新增量时结果为「DB 累计 + 新增量」。idempotent 写的另一侧（同值覆盖）
        // 由 GRDB upsert 测试与采集器重扫测试覆盖。
        let aggregator = UsageAggregator()
        aggregator.ingest(usage: delta, conversationDelta: 1, key: key())
        let written = aggregator.drainTouched()[0]

        let rebuilt = UsageAggregator { $0 == self.key() ? written : nil }
        XCTAssertTrue(rebuilt.touched.isEmpty, "seed 不产生 touched；无新增量不重写")
        XCTAssertTrue(rebuilt.drainTouched().isEmpty)

        rebuilt.ingest(usage: delta, conversationDelta: 1, key: key())
        XCTAssertEqual(rebuilt.drainTouched()[0], written.adding(usage: delta, conversations: 1))
    }

    func test_builder_makesOverviewFromBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 14))!

        let dayStart = calendar.startOfDay(for: now)
        let todayBucket = dayStart.addingTimeInterval(30 * 60)

        let overview = UsageOverviewBuilder.make(
            buckets: [
                UsageBucketState(
                    key: UsageBucketKey(provider: .claude, model: "a", bucketStart: todayBucket),
                    usage: TokenUsage(inputTokens: 0, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 100_000),
                    conversationCount: 3
                ),
                UsageBucketState(
                    key: UsageBucketKey(provider: .claude, model: "b", bucketStart: todayBucket),
                    usage: TokenUsage(inputTokens: 0, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 28_000),
                    conversationCount: 0
                ),
                UsageBucketState(
                    key: UsageBucketKey(provider: .claude, model: "a", bucketStart: todayBucket.addingTimeInterval(-24 * 3600)),
                    usage: TokenUsage(inputTokens: 0, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 168_000),
                    conversationCount: 5
                ),
            ],
            now: now,
            calendar: calendar
        )

        let result = try XCTUnwrap(overview)
        XCTAssertEqual(result.totalTokens, 128_000)
        XCTAssertEqual(result.conversations, 3)
        XCTAssertEqual(result.daily.count, 7)
        XCTAssertEqual(result.daily.last?.totalTokens, 128_000, "最后一项为今日")
        XCTAssertEqual(result.peak?.totalTokens, 168_000, "峰值来自历史日")
        XCTAssertEqual(result.peak?.dayStart, calendar.startOfDay(for: todayBucket.addingTimeInterval(-24 * 3600)))
    }

    func test_builder_emptyWindowReturnsNil() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_784_736_000)
        let oldBucket = Date(timeIntervalSince1970: 1_550_000_000) // 远早于窗口
        XCTAssertNil(UsageOverviewBuilder.make(
            buckets: [
                UsageBucketState(
                    key: UsageBucketKey(provider: .claude, model: "a", bucketStart: oldBucket),
                    usage: TokenUsage(inputTokens: 1, cachedInputTokens: 0, cacheCreationInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1),
                    conversationCount: 0
                ),
            ],
            now: now,
            calendar: calendar
        ))
    }
}
