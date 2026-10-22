import Foundation
import XCTest
@testable import OmniForge

/// Copilot 解析纯函数：session-store.db 行 / OTEL span → 六列、模型、时间、去重 key。
final class CopilotUsageProcessingTests: XCTestCase {
    // MARK: - session-store.db：六列归一化

    func test_sessionStoreTokenUsage_subtractsCacheReadAndWriteFromInput() throws {
        let row = CopilotSessionUsageRow(
            sessionID: "session-1",
            inputTokens: 21_343,
            outputTokens: 100,
            cacheReadTokens: 0,
            cacheWriteTokens: 20_974,
            reasoningTokens: 0
        )
        let usage = try XCTUnwrap(CopilotUsageProcessing.sessionStoreTokenUsage(row))
        XCTAssertEqual(usage.inputTokens, 369, "input = 原始输入 - 缓存读 - 缓存写")
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.cacheCreationInputTokens, 20_974)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.reasoningOutputTokens, 0)
        XCTAssertEqual(usage.totalTokens, 469, "total = input + output + reasoning，缓存不计入")
    }

    func test_sessionStoreTokenUsage_keepsReasoningSeparateFromOutput() throws {
        let row = CopilotSessionUsageRow(
            sessionID: "s",
            inputTokens: 50,
            outputTokens: 30,
            cacheReadTokens: 10,
            reasoningTokens: 12
        )
        let usage = try XCTUnwrap(CopilotUsageProcessing.sessionStoreTokenUsage(row))
        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.cachedInputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.reasoningOutputTokens, 12)
        XCTAssertEqual(usage.totalTokens, 40 + 30 + 12)
    }

    func test_sessionStoreTokenUsage_clampsWhenCacheExceedsInput() throws {
        let row = CopilotSessionUsageRow(
            sessionID: "s",
            inputTokens: 10,
            outputTokens: 0,
            cacheReadTokens: 50,
            cacheWriteTokens: 20
        )
        let usage = try XCTUnwrap(CopilotUsageProcessing.sessionStoreTokenUsage(row))
        XCTAssertEqual(usage.inputTokens, 0, "缓存分项大于输入时非缓存输入归零，不产生负值")
        XCTAssertEqual(usage.cachedInputTokens, 50)
        XCTAssertEqual(usage.cacheCreationInputTokens, 20)
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func test_sessionStoreTokenUsage_returnsNilWhenAllColumnsZero() {
        let row = CopilotSessionUsageRow(sessionID: "s")
        XCTAssertNil(CopilotUsageProcessing.sessionStoreTokenUsage(row))
    }

    // MARK: - session-store.db：模型

    func test_sessionStoreModel_prefersCopilotUsageModel() {
        let row = CopilotSessionUsageRow(
            sessionID: "s",
            model: "gpt-4o",
            copilotUsageModel: " claude-sonnet-4-5 "
        )
        XCTAssertEqual(CopilotUsageProcessing.sessionStoreModel(row), "claude-sonnet-4-5")
    }

    func test_sessionStoreModel_fallsBackToModelThenAuto() {
        let withModel = CopilotSessionUsageRow(sessionID: "s", model: "gpt-5.4-mini")
        XCTAssertEqual(CopilotUsageProcessing.sessionStoreModel(withModel), "gpt-5.4-mini")

        let empty = CopilotSessionUsageRow(sessionID: "s", model: "   ", copilotUsageModel: "")
        XCTAssertEqual(
            CopilotUsageProcessing.sessionStoreModel(empty),
            CopilotUsageProcessing.sessionStoreDefaultModel
        )
        XCTAssertEqual(CopilotUsageProcessing.sessionStoreDefaultModel, "auto")
    }

    // MARK: - session-store.db：时间

    func test_timestampMilliseconds_parsesSQLiteDatetimeAsUTC() throws {
        let milliseconds = try XCTUnwrap(
            CopilotUsageProcessing.timestampMilliseconds(from: "2026-07-01 12:34:56")
        )
        XCTAssertEqual(milliseconds, 1_782_909_296_000)
    }

    func test_timestampMilliseconds_parsesISO8601WithAndWithoutFractionalSeconds() throws {
        let fractional = try XCTUnwrap(
            CopilotUsageProcessing.timestampMilliseconds(from: "2026-07-01T12:34:56.000Z")
        )
        XCTAssertEqual(fractional, 1_782_909_296_000)

        let plain = try XCTUnwrap(
            CopilotUsageProcessing.timestampMilliseconds(from: "2026-07-01T12:34:56Z")
        )
        XCTAssertEqual(plain, 1_782_909_296_000)
    }

    func test_timestampMilliseconds_parsesNumericSecondsAndMilliseconds() throws {
        let seconds = try XCTUnwrap(
            CopilotUsageProcessing.timestampMilliseconds(from: "1782909296")
        )
        XCTAssertEqual(seconds, 1_782_909_296_000)

        let milliseconds = try XCTUnwrap(
            CopilotUsageProcessing.timestampMilliseconds(from: "1782909296000")
        )
        XCTAssertEqual(milliseconds, 1_782_909_296_000)
    }

    func test_timestampMilliseconds_returnsNilForGarbage() {
        XCTAssertNil(CopilotUsageProcessing.timestampMilliseconds(from: "not-a-timestamp"))
        XCTAssertNil(CopilotUsageProcessing.timestampMilliseconds(from: "   "))
        XCTAssertNil(CopilotUsageProcessing.timestampMilliseconds(from: nil))
    }

    func test_sessionStoreTimestamp_fallsBackToSessionCreatedAt() throws {
        let row = CopilotSessionUsageRow(
            sessionID: "s",
            createdAt: "not-a-timestamp",
            sessionCreatedAt: "2026-07-01T12:34:56.000Z"
        )
        let milliseconds = try XCTUnwrap(
            CopilotUsageProcessing.sessionStoreTimestampMilliseconds(row)
        )
        XCTAssertEqual(milliseconds, 1_782_909_296_000)
    }

    // MARK: - session-store.db：事件组装

    func test_sessionStoreEvents_buildsBucketModelKeyAndConversation() throws {
        let row = CopilotSessionUsageRow(
            eventID: 7,
            sessionID: "session-1",
            turnIndex: 0,
            model: "gpt-4o",
            copilotUsageModel: "gpt-5.4-mini",
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            reasoningTokens: 5,
            createdAt: "2026-07-01 12:34:56"
        )
        let events = CopilotUsageProcessing.sessionStoreEvents([row])
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.model, "gpt-5.4-mini")
        XCTAssertEqual(event.usage.inputTokens, 60)
        XCTAssertEqual(event.usage.cachedInputTokens, 30)
        XCTAssertEqual(event.usage.cacheCreationInputTokens, 10)
        XCTAssertEqual(event.usage.outputTokens, 20)
        XCTAssertEqual(event.usage.reasoningOutputTokens, 5)
        XCTAssertEqual(event.usage.totalTokens, 60 + 20 + 5)
        XCTAssertEqual(event.bucketStart.timeIntervalSince1970, 1_782_909_000, "UTC 半小时桶")
        XCTAssertEqual(event.deduplicationKey, "copilot:session-1:event:7")
        XCTAssertEqual(event.conversationDelta, 1)
    }

    func test_sessionStoreEvents_dedupesDuplicateEventID() {
        let row = CopilotSessionUsageRow(
            eventID: 1,
            sessionID: "session-1",
            inputTokens: 10,
            createdAt: "2026-07-01 12:34:56"
        )
        let events = CopilotUsageProcessing.sessionStoreEvents([row, row])
        XCTAssertEqual(events.count, 1, "同一事件主键同批只计一次")
    }

    func test_sessionStoreEvents_countsConversationOncePerTurn() {
        let rows = [
            CopilotSessionUsageRow(
                eventID: 1,
                sessionID: "session-1",
                turnIndex: 3,
                inputTokens: 10,
                createdAt: "2026-07-01 12:34:56"
            ),
            CopilotSessionUsageRow(
                eventID: 2,
                sessionID: "session-1",
                turnIndex: 3,
                inputTokens: 20,
                createdAt: "2026-07-01 12:34:56"
            ),
            CopilotSessionUsageRow(
                eventID: 3,
                sessionID: "session-1",
                turnIndex: 4,
                inputTokens: 30,
                createdAt: "2026-07-01 12:34:56"
            ),
        ]
        let events = CopilotUsageProcessing.sessionStoreEvents(rows)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.conversationDelta), [1, 0, 1], "同一会话轮次只计 1 次会话")
    }

    func test_sessionStoreEvents_dropsRowsWithUnrecoverableTimestamp() {
        let row = CopilotSessionUsageRow(
            eventID: 1,
            sessionID: "session-1",
            inputTokens: 10,
            createdAt: "not-a-timestamp",
            sessionCreatedAt: "also-bad"
        )
        XCTAssertTrue(
            CopilotUsageProcessing.sessionStoreEvents([row]).isEmpty,
            "时间无法恢复时宁可漏计，也不落入错误时间桶"
        )
    }

    func test_sessionStoreEvents_skipsEmptySessionID() {
        let row = CopilotSessionUsageRow(
            eventID: 1,
            sessionID: "   ",
            inputTokens: 10,
            createdAt: "2026-07-01 12:34:56"
        )
        XCTAssertTrue(CopilotUsageProcessing.sessionStoreEvents([row]).isEmpty)
    }

    func test_sessionStoreEvents_fallbackKeyIsStableWithoutEventID() throws {
        let row = CopilotSessionUsageRow(
            sessionID: "session-1",
            model: "gpt-5.4-mini",
            inputTokens: 10,
            outputTokens: 2,
            createdAt: "2026-07-01 12:34:56"
        )
        let first = try XCTUnwrap(CopilotUsageProcessing.sessionStoreEvents([row]).first)
        let second = try XCTUnwrap(CopilotUsageProcessing.sessionStoreEvents([row]).first)
        XCTAssertEqual(first.deduplicationKey, second.deduplicationKey, "无事件 id 时时间+用量签名应稳定")
        XCTAssertTrue(first.deduplicationKey.hasPrefix("copilot:session-1:ts:"))
    }

    // MARK: - OTEL：单 span 归一化

    func test_otelChatSpan_normalizesUsageModelAndDedupKey() throws {
        let record = otelRecord("""
        {"type":"span","traceId":"trace-1","spanId":"span-1","name":"chat claude-sonnet-4.5",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"claude-sonnet-4.5",
         "gen_ai.conversation.id":"conv-1","gen_ai.usage.input_tokens":100,
         "gen_ai.usage.output_tokens":20,"gen_ai.usage.cache_read.input_tokens":40,
         "gen_ai.usage.reasoning.output_tokens":5}}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [record],
            fallbackTimestampMilliseconds: nil
        )
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.model, "claude-sonnet-4.5")
        XCTAssertEqual(event.usage.inputTokens, 60, "OTel input_tokens 含缓存读，只扣除 cache_read")
        XCTAssertEqual(event.usage.cachedInputTokens, 40)
        XCTAssertEqual(event.usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(event.usage.outputTokens, 20)
        XCTAssertEqual(event.usage.reasoningOutputTokens, 5)
        XCTAssertEqual(event.usage.totalTokens, 60 + 20 + 5)
        XCTAssertEqual(event.bucketStart.timeIntervalSince1970, 1_775_934_000)
        XCTAssertEqual(event.deduplicationKey, "copilot:conv-1:span:trace-1:span-1")
        XCTAssertEqual(event.conversationDelta, 1)
    }

    func test_otelSpanWithoutModel_inheritsTraceContextFromSiblingRecord() throws {
        let usageSpan = otelRecord("""
        {"type":"span","traceId":"trace-ctx","spanId":"span-chat","name":"chat",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv-ctx",
         "gen_ai.usage.input_tokens":40,"gen_ai.usage.output_tokens":4}}
        """)
        let contextSpan = otelRecord("""
        {"type":"span","traceId":"trace-ctx","spanId":"span-invoke","name":"invoke_agent",
         "startTime":[1775934260,0],
         "attributes":{"gen_ai.operation.name":"invoke_agent",
         "gen_ai.request.model":"claude-sonnet-4.5"}}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [usageSpan, contextSpan],
            fallbackTimestampMilliseconds: nil
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.model, "claude-sonnet-4.5", "模型可从同 trace 的其它记录回填")
    }

    func test_otelChatSpanSuppressesInferenceLogInSameTrace() {
        let chatSpan = otelRecord("""
        {"type":"span","traceId":"trace-1","spanId":"span-1","name":"chat gpt-5.4-mini",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":42,"gen_ai.usage.output_tokens":7}}
        """)
        let inferenceLog = otelRecord("""
        {"type":"log","spanContext":{"traceId":"trace-1","spanId":"log-1"},
         "hrTime":[1775934264,0],
         "attributes":{"event.name":"gen_ai.client.inference.operation.details",
         "gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":10,"gen_ai.usage.output_tokens":2},
         "_body":"GenAI inference: gpt-5.4-mini"}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [chatSpan, inferenceLog],
            fallbackTimestampMilliseconds: nil
        )
        XCTAssertEqual(events.count, 1, "同一 trace 的 chat span 与 inference log 只保留 chat，避免重复计费")
        XCTAssertEqual(events.first?.usage.totalTokens, 49)
    }

    func test_otelInferenceLogInDifferentTraceIsCounted() {
        let chatSpan = otelRecord("""
        {"type":"span","traceId":"trace-a","spanId":"span-a","name":"chat gpt-5.4-mini",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":42,"gen_ai.usage.output_tokens":7}}
        """)
        let otherTracesLog = otelRecord("""
        {"type":"log","spanContext":{"traceId":"trace-b","spanId":"log-b"},
         "hrTime":[1775934264,0],
         "attributes":{"event.name":"gen_ai.client.inference.operation.details",
         "gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":10,"gen_ai.usage.output_tokens":2},
         "_body":"GenAI inference: gpt-5.4-mini"}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [chatSpan, otherTracesLog],
            fallbackTimestampMilliseconds: nil
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.deduplicationKey)).count, 2)
    }

    func test_otelDuplicateSpanSnapshotsMergeWithMaxTokens() {
        let first = otelRecord("""
        {"type":"span","traceId":"trace-1","spanId":"span-1","name":"chat",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":42,"gen_ai.usage.output_tokens":7}}
        """)
        let second = otelRecord("""
        {"type":"span","traceId":"trace-1","spanId":"span-1","name":"chat",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":9}}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [first, second],
            fallbackTimestampMilliseconds: nil
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.usage.inputTokens, 100)
        XCTAssertEqual(events.first?.usage.outputTokens, 9)
    }

    func test_otelStableIdentityWithoutTimestamp_usesFileModificationTime() throws {
        let record = otelRecord("""
        {"type":"span","traceId":"trace-1","spanId":"span-1","name":"chat",
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv",
         "gen_ai.usage.input_tokens":5,"gen_ai.usage.output_tokens":1}}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [record],
            fallbackTimestampMilliseconds: 1_782_909_296_000
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.bucketStart.timeIntervalSince1970, 1_782_909_000)
    }

    func test_otelRecordWithoutIdentityAndTimestamp_isDropped() {
        let record = otelRecord("""
        {"type":"span","name":"chat",
         "attributes":{"gen_ai.operation.name":"chat",
         "gen_ai.usage.input_tokens":5,"gen_ai.usage.output_tokens":1}}
        """)
        let events = CopilotUsageProcessing.otelEvents(
            records: [record],
            fallbackTimestampMilliseconds: 1_782_909_296_000
        )
        XCTAssertTrue(events.isEmpty, "无全局身份又无自带时间时丢弃，避免 mtime 变化导致重复计数")
    }

    func test_otelZeroUsageRecord_isIgnored() {
        let record = otelRecord("""
        {"type":"span","traceId":"trace-1","spanId":"span-1","name":"chat",
         "startTime":[1775934264,0],
         "attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"conv"}}
        """)
        XCTAssertTrue(CopilotUsageProcessing.otelEvents(
            records: [record],
            fallbackTimestampMilliseconds: nil
        ).isEmpty)
    }

    func test_parseOTELLine_rejectsMalformedLines() {
        XCTAssertNil(CopilotUsageProcessing.parseOTELLine("not-json"))
        XCTAssertNil(CopilotUsageProcessing.parseOTELLine("   "))
        XCTAssertNil(CopilotUsageProcessing.parseOTELLine("[1,2,3]"))
        XCTAssertNotNil(CopilotUsageProcessing.parseOTELLine(#"{"a":1}"#))
    }

    // MARK: - 工具

    private func otelRecord(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any] else {
            XCTFail("测试 JSON 不合法: \(json)")
            return [:]
        }
        return record
    }
}
