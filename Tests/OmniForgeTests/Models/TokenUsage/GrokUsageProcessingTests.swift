import XCTest
@testable import OmniForge

/// grok updates.jsonl 行解析 — turn 用量提取（modelUsage 拆分）/ 时间自适应 / 模型规范化 / 兜底估算。
final class GrokUsageProcessingTests: XCTestCase {

    // MARK: - 六列归一化

    func test_tokenUsage_splitsCachedFromInput() throws {
        let usage = GrokTurnUsage(
            inputTokens: 100_000,
            outputTokens: 500,
            cachedReadTokens: 20_000,
            reasoningTokens: 100,
            totalTokens: 100_500,
            modelUsage: nil
        )
        let tokens = GrokUsageProcessing.tokenUsage(from: usage)
        XCTAssertNotNil(tokens)
        XCTAssertEqual(tokens?.inputTokens, 80_000, "input 含缓存 → 拆分纯非缓存")
        XCTAssertEqual(tokens?.cachedInputTokens, 20_000)
        XCTAssertEqual(tokens?.outputTokens, 500)
        XCTAssertEqual(tokens?.reasoningOutputTokens, 100)
        XCTAssertEqual(tokens?.totalTokens, 80_000 + 20_000 + 500, "total 为四列之和")
    }

    func test_tokenUsage_nilWhenAllZero() {
        XCTAssertNil(GrokUsageProcessing.tokenUsage(from: GrokTurnUsage(
            inputTokens: 0, outputTokens: 0, cachedReadTokens: 0, reasoningTokens: 0,
            totalTokens: 0, modelUsage: nil
        )))
    }

    // MARK: - turn 事件提取

    func test_turnEvents_splitsByModelUsage() throws {
        let line = """
        {"timestamp":1784357100,"method":"session/update","params":{"sessionId":"s1","update":\
        {"sessionUpdate":"turn_completed","prompt_id":"p1","stop_reason":"end_turn","usage":\
        {"inputTokens":100,"outputTokens":200,"totalTokens":300,"cachedReadTokens":40,"reasoningTokens":10,\
        "modelUsage":{"grok-4.5-build":{"inputTokens":100,"outputTokens":200,"totalTokens":300,"cachedReadTokens":40,"reasoningTokens":10},\
        "grok-mini":{"inputTokens":50,"outputTokens":20,"totalTokens":70}}}}, \
        "_meta":{"totalTokens":12000,"eventId":"s1-e1","agentTimestampMs":1784357100000}}}
        """
        let record = try JSONDecoder().decode(GrokUpdateRecord.self, from: Data(line.utf8))
        let events = GrokUsageProcessing.turnEvents(from: record, fallbackModel: "grok-build", lineIndex: 1)
        XCTAssertEqual(events.count, 2, "modelUsage 拆分两个模型")
        let main = events.first { $0.model == "grok-4.5-build" }
        XCTAssertNotNil(main)
        XCTAssertEqual(main?.usage.inputTokens, 60)
        XCTAssertEqual(main?.usage.cachedInputTokens, 40)
        XCTAssertEqual(main?.dedupKey, "grok:s1-e1|grok-4.5-build")
        let mini = events.first { $0.model == "grok-mini" }
        XCTAssertEqual(mini?.usage.outputTokens, 20)
        XCTAssertEqual(mini?.dedupKey, "grok:s1-e1|grok-mini")
    }

    func test_turnEvents_singleFallbackWhenNoModelUsage() throws {
        let line = """
        {"timestamp":1784357100,"params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed",\
        "usage":{"inputTokens":1000,"outputTokens":200,"totalTokens":1200,"cachedReadTokens":100}}, \
        "_meta":{"eventId":"e-1","agentTimestampMs":1784357100000}}}
        """
        let record = try JSONDecoder().decode(GrokUpdateRecord.self, from: Data(line.utf8))
        let events = GrokUsageProcessing.turnEvents(from: record, fallbackModel: "grok-4.5", lineIndex: 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "grok-4.5")
        XCTAssertEqual(events[0].usage.inputTokens, 900, "1000 - cached 100")
        XCTAssertEqual(events[0].usage.cachedInputTokens, 100)
        XCTAssertEqual(events[0].timestampMs, 1_784_357_100_000)
    }

    func test_turnEvents_emptyForNonTurnOrMissingEventID() throws {
        let nonTurn = """
        {"timestamp":1784357100,"params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk",\
        "content":{"type":"text"}},"_meta":{"eventId":"e1","agentTimestampMs":1784357100000}}}
        """
        let r1 = try JSONDecoder().decode(GrokUpdateRecord.self, from: Data(nonTurn.utf8))
        XCTAssertTrue(GrokUsageProcessing.turnEvents(from: r1, fallbackModel: "grok-build", lineIndex: 1).isEmpty)

        let noID = """
        {"timestamp":1784357100,"params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed",\
        "usage":{"inputTokens":1},"_meta":{"agentTimestampMs":1784357100000}}}}
        """
        let r2 = try JSONDecoder().decode(GrokUpdateRecord.self, from: Data(noID.utf8))
        XCTAssertTrue(GrokUsageProcessing.turnEvents(from: r2, fallbackModel: "grok-build", lineIndex: 1).isEmpty,
                      "无事件 id → 不可去重，保守跳过")
    }

    // MARK: - 模型规范化

    func test_canonicalizeModelName() {
        XCTAssertEqual(GrokUsageProcessing.canonicalizeModelName("grok-4.5-build"), "grok-4.5-build")
        XCTAssertEqual(GrokUsageProcessing.canonicalizeModelName("grok-4-5-build"), "grok-4.5-build")
        XCTAssertEqual(GrokUsageProcessing.canonicalizeModelName("grok-4.5-build-free"), "grok-build-free")
        XCTAssertEqual(GrokUsageProcessing.canonicalizeModelName("grok-4.5"), "grok-4.5")
        XCTAssertEqual(GrokUsageProcessing.canonicalizeModelName(nil), "grok-build")
        XCTAssertEqual(GrokUsageProcessing.canonicalizeModelName(""), "grok-build")
    }

    // MARK: - 时间

    func test_toMilliseconds_secondsAndMillis() {
        XCTAssertEqual(GrokUsageProcessing.toMilliseconds(1_784_357_100), 1_784_357_100_000, "秒 → 毫秒")
        XCTAssertEqual(GrokUsageProcessing.toMilliseconds(1_784_357_100_000), 1_784_357_100_000, "毫秒原样")
        XCTAssertNil(GrokUsageProcessing.toMilliseconds(nil))
        XCTAssertNil(GrokUsageProcessing.toMilliseconds(0))
    }

    func test_bucketStart_roundsToHalfHour() {
        // 1_784_357_100 → 半小时起点 1_784_356_200。
        let start = GrokUsageProcessing.bucketStart(fromMilliseconds: 1_784_357_100_000)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_784_356_200))
    }

    // MARK: - 快照兜底

    func test_effectiveSignalTotal_prefersCompactionPlusContext() throws {
        let signals = try JSONDecoder().decode(GrokSignals.self, from: Data("""
        {"contextTokensUsed":90000,"totalTokensBeforeCompaction":200000,"totalTokens":12000,"primaryModelId":"grok-4.5-build"}
        """.utf8))
        XCTAssertEqual(GrokUsageProcessing.effectiveSignalTotal(signals), 290_000,
                       "contextTokensUsed + beforeCompaction > totalTokens")
    }

    func test_effectiveSignalTotal_withoutContextField() throws {
        let signals = try JSONDecoder().decode(GrokSignals.self, from: Data("""
        {"totalTokens":5000,"totalTokensBeforeCompaction":7000}
        """.utf8))
        XCTAssertEqual(GrokUsageProcessing.effectiveSignalTotal(signals), 12_000)
    }

    func test_estimatedUsage_inputRatioEightyPercent() {
        let usage = GrokUsageProcessing.estimatedUsage(totalTokens: 10_000)
        XCTAssertEqual(usage.totalTokens, 10_000)
        XCTAssertEqual(usage.inputTokens, 8_000)
        XCTAssertEqual(usage.outputTokens, 2_000)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.reasoningOutputTokens, 0)
    }

    func test_isoToMilliseconds_parsesFractionalISO() {
        XCTAssertEqual(
            GrokUsageProcessing.isoToMilliseconds("2026-07-18T10:00:00.000Z"),
            1_784_368_800_000
        )
        XCTAssertEqual(
            GrokUsageProcessing.isoToMilliseconds("2026-07-18T10:00:00Z"),
            1_784_368_800_000
        )
        XCTAssertNil(GrokUsageProcessing.isoToMilliseconds(nil))
        XCTAssertNil(GrokUsageProcessing.isoToMilliseconds("garbage"))
    }
}