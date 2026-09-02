import Foundation
import XCTest
@testable import OmniForge

/// Codex rollout 行解析 — cached 减法、增量口径、去重 key、半小时桶（SPEC 8 / 参考 02）。
final class CodexUsageProcessingTests: XCTestCase {

    // MARK: - 六列归一化 + cached 减法

    func test_normalized_appliesCachedSubtraction_andRecalculatesTotal() throws {
        // Codex 的 input_tokens 含缓存总 prompt，cached 是其子集 → 必须减掉（参考 02/08）。
        let counts = makeCounts(input: 100, cached: 80, creation: 0, output: 10, total: 999)
        let usage = try XCTUnwrap(CodexUsageProcessing.normalized(from: counts))
        XCTAssertEqual(usage.inputTokens, 20, "input = max(0, 100 - 80)")
        XCTAssertEqual(usage.cachedInputTokens, 80)
        XCTAssertEqual(usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.reasoningOutputTokens, 0)
        XCTAssertEqual(usage.totalTokens, 30, "total = input + output（缓存两列不计入总量），不信任事件中的累计字段")
        XCTAssertEqual(usage.adding(usage).totalTokens, 60, "叠加幂等语义正常")
    }

    func test_normalized_usesCacheWriteAliasForCreation() throws {
        var counts = makeCounts(input: 10, cached: 0, creation: nil, output: 0, total: 10)
        counts.cacheWriteInputTokens = 30
        let usage = try XCTUnwrap(CodexUsageProcessing.normalized(from: counts))
        XCTAssertEqual(usage.cacheCreationInputTokens, 30, "cache_write_input_tokens 是 cache_creation 的别名")
        XCTAssertEqual(usage.totalTokens, 10, "缓存写进分项列，不计入总量")
    }

    func test_normalized_clampsNegativesToZero() throws {
        let usage = try XCTUnwrap(CodexUsageProcessing.normalized(
            from: CodexTokenCounts(inputTokens: -5, cachedInputTokens: 10, cacheCreationInputTokens: nil, cacheWriteInputTokens: nil, outputTokens: 3, reasoningOutputTokens: nil, totalTokens: -1)
        ))
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.cachedInputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.totalTokens, 3)
    }

    func test_normalized_allZeroReturnsNil() {
        let counts = makeCounts(input: 0, cached: 0, creation: 0, output: 0, total: 0)
        XCTAssertNil(CodexUsageProcessing.normalized(from: counts), "全零行不产生计数")
    }

    // MARK: - 行级增量口径

    func test_delta_prefersLastTokenUsage_whenPresent() throws {
        // 每个 token_count 事件的 last_token_usage 即「最新完成轮次」的用量。
        let last = makeCounts(input: 30, cached: 5, creation: 0, output: 5, total: 40)
        let total = makeCounts(input: 300, cached: 50, creation: 0, output: 40, total: 390)
        let delta = try XCTUnwrap(CodexUsageProcessing.delta(
            last: last, total: total, previousTotal: nil, isStreamStart: true
        ))
        XCTAssertEqual(delta.inputTokens, 25, "last 归一化时同样做 cached 减法")
        XCTAssertEqual(delta.totalTokens, 30, "total = input + output：25 + 5，不信任事件累计字段（40 为未减口径）")
    }

    func test_delta_lastSkipsWhenCumulativeTotalUnchanged() {
        // 同一轮次的 last 快照重发（时间戳不同 → 去重 key 失效）：累计总量未变，
        // 该快照已涵盖在既有差值口径中，不得重复计费（参考 consumeUsageDelta 基线命中返 null）。
        let last = makeCounts(input: 30, cached: 5, creation: 0, output: 5, total: 40)
        let total = makeCounts(input: 300, cached: 50, creation: 0, output: 40, total: 390)
        XCTAssertNil(CodexUsageProcessing.delta(
            last: last, total: total, previousTotal: total, isStreamStart: false
        ))
    }

    func test_delta_lastCountsWhenCumulativeAdvanced() throws {
        // 总量与上次不同 → 是新完成的轮次，正常计数。
        let last = makeCounts(input: 30, cached: 5, creation: 0, output: 5, total: 40)
        let previous = makeCounts(input: 200, cached: 40, creation: 0, output: 30, total: 270)
        let total = makeCounts(input: 300, cached: 50, creation: 0, output: 40, total: 390)
        let delta = try XCTUnwrap(CodexUsageProcessing.delta(
            last: last, total: total, previousTotal: previous, isStreamStart: false
        ))
        XCTAssertEqual(delta.totalTokens, 30)
    }

    func test_delta_fallsBackToTotalDelta_withPreviousTotal() throws {
        let prev = makeCounts(input: 80, cached: 40, creation: 0, output: 10, total: 130)
        let total = makeCounts(input: 100, cached: 50, creation: 0, output: 20, total: 170)
        let delta = try XCTUnwrap(CodexUsageProcessing.delta(
            last: nil, total: total, previousTotal: prev, isStreamStart: false
        ))
        XCTAssertEqual(delta.inputTokens, 10, "total - previous 的逐字段差值，差值同样做 cached 减法（20 - 10）")
        XCTAssertEqual(delta.cachedInputTokens, 10)
        XCTAssertEqual(delta.outputTokens, 10)
        XCTAssertEqual(delta.totalTokens, 20, "按不含缓存口径重算：10 + 0 + 10")
    }

    func test_delta_streamStartCountsTotal_whenNoLastExists() throws {
        // 空文件/截断重读的整读开始：无 last 也把累计值记为首次增量（参考 consumeUsageDelta 兜底）。
        let total = makeCounts(input: 60, cached: 10, creation: 0, output: 5, total: 75)
        let delta = try XCTUnwrap(CodexUsageProcessing.delta(
            last: nil, total: total, previousTotal: nil, isStreamStart: true
        ))
        XCTAssertEqual(delta.inputTokens, 50)
        XCTAssertEqual(delta.totalTokens, 55)
    }

    func test_delta_incrementalTailWithoutLast_isSkipped() {
        // 增量尾部出现「无 last 且无本文件内上一轮累计」的事件：无法确定差值，
        // 保守跳过而不是把累计值当增量重复计费。
        let total = makeCounts(input: 60, cached: 10, creation: 0, output: 5, total: 75)
        XCTAssertNil(CodexUsageProcessing.delta(
            last: nil, total: total, previousTotal: nil, isStreamStart: false
        ))
    }

    func test_delta_lastAllZeroCountsNothing() {
        let allZero = makeCounts(input: 0, cached: 0, creation: 0, output: 0, total: 0)
        XCTAssertNil(CodexUsageProcessing.delta(
            last: allZero, total: makeCounts(input: 100, cached: 0, creation: 0, output: 0, total: 100),
            previousTotal: nil, isStreamStart: true
        ), "last 全零即该轮无用量（last 优先 ≠ 回退 total）")
    }

    func test_delta_totalsReset_returnsNil() {
        // 会话内累计值回退（stream 轮换）：不跨流累加，避免把新流累计量算进旧流。
        let prev = makeCounts(input: 20, cached: 0, creation: 0, output: 0, total: 40)
        let reset = makeCounts(input: 10, cached: 0, creation: 0, output: 0, total: 15)
        XCTAssertNil(CodexUsageProcessing.delta(
            last: nil, total: reset, previousTotal: prev, isStreamStart: false
        ))
    }

    // MARK: - 去重 key

    func test_eventKey_requiresTimestamp() {
        XCTAssertNil(CodexUsageProcessing.eventKey(
            sessionID: "s1", timestamp: nil, last: nil, total: nil
        ))
        XCTAssertNil(CodexUsageProcessing.eventKey(
            sessionID: "s1", timestamp: "", last: nil, total: nil
        ))
    }

    func test_eventKey_composesSessionTimestampSignature() {
        let last = makeCounts(input: 30, cached: 5, creation: 0, output: 5, total: 40)
        let key = CodexUsageProcessing.eventKey(
            sessionID: "s-1", timestamp: "2026-08-22T01:50:04Z", last: last, total: nil
        )
        XCTAssertEqual(key, "s-1:2026-08-22T01:50:04Z:30:5:0:5:0:40:none", "会话 id + 时间戳 + 用量签名（无 requestId 语义）")
    }

    func test_eventKey_signatureDistinguishesLastTotalPairs() {
        let lastA = makeCounts(input: 1, cached: 0, creation: 0, output: 0, total: 1)
        let lastB = makeCounts(input: 2, cached: 0, creation: 0, output: 0, total: 2)
        let keyA = CodexUsageProcessing.eventKey(sessionID: "s", timestamp: "t", last: lastA, total: nil)
        let keyB = CodexUsageProcessing.eventKey(sessionID: "s", timestamp: "t", last: lastB, total: nil)
        XCTAssertNotEqual(keyA, keyB, "不同 last/total 组合 → 不同签名，不误去重")
        XCTAssertEqual(keyA, CodexUsageProcessing.eventKey(sessionID: "s", timestamp: "t", last: lastA, total: nil))
    }

    // MARK: - 事件提取

    func test_tokenCountResource_readsPayloadInfo() throws {
        let entry = CodexRolloutEntry.from(json: """
        {"type":"event_msg","timestamp":"2026-08-22T01:50:04Z",\
        "payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"total_tokens":10}}}}
        """)
        XCTAssertTrue(entry?.isTokenCountEvent == true)
        XCTAssertEqual(entry?.tokenCountResource?.totalTokenUsage?.inputTokens, 10)
    }

    func test_tokenCountResource_readsPayloadMsgFallback() throws {
        let entry = CodexRolloutEntry.from(json: """
        {"type":"event_msg","timestamp":"2026-08-22T01:50:04Z",\
        "payload":{"msg":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"total_tokens":7}}}}}
        """)
        XCTAssertTrue(entry?.isTokenCountEvent == true)
        XCTAssertEqual(entry?.tokenCountResource?.totalTokenUsage?.inputTokens, 7)
    }

    func test_turnContextAndSessionMetaCarryModelInfo() throws {
        let turn = CodexRolloutEntry.from(json: """
        {"type":"turn_context","timestamp":"2026-08-22T01:50:04Z","payload":{"cwd":"/x","model":"gpt-5-codex"}}
        """)
        XCTAssertEqual(turn?.payload?.model, "gpt-5-codex")
        let meta = CodexRolloutEntry.from(json: """
        {"type":"session_meta","payload":{"id":"11111111-2222-3333-4444-555555555555","model_provider":"openai"}}
        """)
        XCTAssertEqual(meta?.payload?.id, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(meta?.payload?.modelProvider, "openai")
    }

    // MARK: - 时间桶与模型名

    func test_bucketStart_floorsToUtcHalfHour() {
        let start = CodexUsageProcessing.bucketStart(from: "2026-08-22T01:50:04.123Z")
        let expected = ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z")!
        XCTAssertEqual(start?.timeIntervalSince1970, expected.timeIntervalSince1970)
        XCTAssertEqual(
            ISO8601DateFormatter().string(from: start!),
            "2026-08-22T01:30:00Z"
        )
    }

    func test_bucketStart_invalidTimestampReturnsNil() {
        XCTAssertNil(CodexUsageProcessing.bucketStart(from: "not-a-date"))
        XCTAssertNil(CodexUsageProcessing.bucketStart(from: nil))
    }

    func test_modelName_trimsAndDefaults() {
        XCTAssertEqual(CodexUsageProcessing.modelName(" gpt-5-codex "), "gpt-5-codex")
        XCTAssertEqual(CodexUsageProcessing.modelName(""), "unknown")
        XCTAssertEqual(CodexUsageProcessing.modelName(nil), "unknown")
    }

    // MARK: - 工具

    private func makeCounts(
        input: Int, cached: Int, creation: Int?, output: Int, total: Int
    ) -> CodexTokenCounts {
        CodexTokenCounts(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: creation,
            cacheWriteInputTokens: nil,
            outputTokens: output,
            reasoningOutputTokens: nil,
            totalTokens: total
        )
    }
}

extension CodexRolloutEntry {
    /// 测试辅助：从 JSON 字符串解码行。
    static func from(json: String) -> CodexRolloutEntry? {
        try? JSONDecoder().decode(CodexRolloutEntry.self, from: Data(json.utf8))
    }
}
