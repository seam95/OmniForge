import XCTest
@testable import OmniForge

/// Claude transcript 行解析：去重 key、六列归一化、半小时桶 — 纯逻辑（参考 02）。
final class ClaudeUsageProcessingTests: XCTestCase {

    // MARK: - 去重 key

    func test_dedupKey_messageIdOnlyWhenNoRequestID() {
        XCTAssertEqual(
            ClaudeUsageProcessing.deduplicationKey(messageID: "msg_1", requestID: nil),
            "msg_1"
        )
        XCTAssertEqual(
            ClaudeUsageProcessing.deduplicationKey(messageID: "msg_1", requestID: ""),
            "msg_1",
            "空 requestId 视为无值"
        )
    }

    func test_dedupKey_messageIdPlusRequestIDWhenPresent() {
        XCTAssertEqual(
            ClaudeUsageProcessing.deduplicationKey(messageID: "msg_1", requestID: "req_2"),
            "msg_1:req_2"
        )
    }

    func test_dedupKey_nilWhenNoMessageId() {
        XCTAssertNil(ClaudeUsageProcessing.deduplicationKey(messageID: nil, requestID: "req_2"))
        XCTAssertNil(ClaudeUsageProcessing.deduplicationKey(messageID: "", requestID: "req_2"))
        XCTAssertNil(ClaudeUsageProcessing.deduplicationKey(messageID: nil, requestID: nil))
    }

    func test_userDedupKey_prefixedWithU() {
        XCTAssertEqual(ClaudeUsageProcessing.userDeduplicationKey(uuid: "abc-123"), "u:abc-123")
        XCTAssertNil(ClaudeUsageProcessing.userDeduplicationKey(uuid: nil))
        XCTAssertNil(ClaudeUsageProcessing.userDeduplicationKey(uuid: ""))
    }

    // MARK: - 归一化（六列）

    func test_tokenUsage_normalizesClaudeColumns() {
        let line = assistantLine(
            id: "msg_1",
            model: "claude-sonnet-4-5",
            usage: [
                "input_tokens": 100,
                "cache_creation_input_tokens": 20,
                "cache_read_input_tokens": 30,
                "output_tokens": 10,
                "service_tier": "standard",
            ]
        )
        let entry = decode(line)
        let usage = ClaudeUsageProcessing.tokenUsage(from: entry)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 100)
        XCTAssertEqual(usage?.cachedInputTokens, 30, "cache_read 并入 cached 列")
        XCTAssertEqual(usage?.cacheCreationInputTokens, 20)
        XCTAssertEqual(usage?.outputTokens, 10)
        XCTAssertEqual(usage?.reasoningOutputTokens, 0, "Claude 口径 reasoning 不单列（output 已含）")
        XCTAssertEqual(usage?.totalTokens, 110, "total = input + output（缓存两列不计入总量）")
    }

    func test_tokenUsage_missingFieldsDefaultToZero() {
        let entry = decode(assistantLine(id: "msg_2", model: nil, usage: ["output_tokens": 5]))
        let usage = ClaudeUsageProcessing.tokenUsage(from: entry)
        XCTAssertEqual(usage?.inputTokens, 0)
        XCTAssertEqual(usage?.cachedInputTokens, 0)
        XCTAssertEqual(usage?.totalTokens, 5)
    }

    func test_tokenUsage_negativeValuesClampedToZero() {
        let entry = decode(assistantLine(
            id: "msg_3",
            model: "claude-opus-4-8",
            usage: ["input_tokens": -7, "output_tokens": 3]
        ))
        let usage = ClaudeUsageProcessing.tokenUsage(from: entry)
        XCTAssertEqual(usage?.inputTokens, 0)
        XCTAssertEqual(usage?.outputTokens, 3)
    }

    func test_tokenUsage_allZeroSkipped() {
        let entry = decode(assistantLine(id: "msg_4", model: nil, usage: ["input_tokens": 0, "output_tokens": 0]))
        XCTAssertNil(ClaudeUsageProcessing.tokenUsage(from: entry), "全零行不产生计数")
    }

    func test_tokenUsage_ignoresNonAssistantOrUsageLessLines() {
        let noUsage = decode(userLine(uuid: "u_1", content: [[ "type": "text", "text": "你好" ]]))
        XCTAssertNil(ClaudeUsageProcessing.tokenUsage(from: noUsage))
        let systemLine = decode("""
        {"type":"mode","mode":"default","sessionId":"s1"}
        """)
        XCTAssertNil(ClaudeUsageProcessing.tokenUsage(from: systemLine))
    }

    func test_decode_neverMaterializesMessageContent() {
        // 红线：正文（text）字段存在时解码成功且只暴露 type —— 永不存储正文。
        let line = assistantLine(
            id: "msg_5",
            model: "deepseek-v4-flash",
            usage: ["input_tokens": 10, "output_tokens": 4]
        )
        let entry = decode(line)
        XCTAssertEqual(entry.type, "assistant")
        XCTAssertEqual(entry.message?.content?.map(\.type), ["text"], "只解码 type 标记，不读 text")
        XCTAssertEqual(entry.requestId, nil)
    }

    // MARK: - 半小时桶

    func test_halfHourStart_floorsToUTCBucket() {
        let ts = utcDate("2026-08-22T01:50:04Z")
        XCTAssertEqual(
            ClaudeUsageProcessing.halfHourStart(for: ts),
            utcDate("2026-08-22T01:30:00Z")
        )
        let boundary = utcDate("2026-08-22T01:29:59Z")
        XCTAssertEqual(
            ClaudeUsageProcessing.halfHourStart(for: boundary),
            utcDate("2026-08-22T01:00:00Z")
        )
    }

    func test_bucketStart_parsesIsoTimestamp() {
        XCTAssertEqual(
            ClaudeUsageProcessing.bucketStart(from: "2026-08-22T01:50:04Z"),
            utcDate("2026-08-22T01:30:00Z")
        )
        XCTAssertEqual(
            ClaudeUsageProcessing.bucketStart(from: "2026-08-22T01:50:04.376Z"),
            utcDate("2026-08-22T01:30:00Z"),
            "毫秒小数不影响桶"
        )
        XCTAssertNil(ClaudeUsageProcessing.bucketStart(from: nil))
        XCTAssertNil(ClaudeUsageProcessing.bucketStart(from: "not-a-date"))
    }

    func test_tokenUsage_modelNameTrimPadding() {
        XCTAssertEqual(ClaudeUsageProcessing.modelName("  claude-3.5-sonnet  "), "claude-3.5-sonnet")
        XCTAssertEqual(ClaudeUsageProcessing.modelName(""), "unknown")
        XCTAssertEqual(ClaudeUsageProcessing.modelName(nil), "unknown")
    }

    // MARK: - 工具

    private func utcDate(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    private func decode(_ json: String) -> ClaudeTranscriptEntry {
        try! JSONDecoder().decode(ClaudeTranscriptEntry.self, from: Data(json.utf8))
    }

    private func assistantLine(
        id: String?,
        model: String?,
        usage: [String: Any]
    ) -> String {
        let usagePairs = usage.map { "\"\($0)\":\(jsonValue($1))" }.joined(separator: ",")
        let usageJSON = usagePairs.isEmpty ? "" : "\"usage\":{\(usagePairs)},"
        let message = """
        {"id":\(jsonValue(id)),"type":"assistant","role":"assistant","model":\(jsonValue(model)),\
        \(usageJSON)"content":[{"type":"text","text":"sampled reply (not read)"}]}
        """
        return """
        {"type":"assistant","timestamp":"2026-08-22T01:50:04Z","uuid":"line-uuid","requestId":null,\
        "message":\(message),"sessionId":"sess-1"}
        """
    }

    private func userLine(uuid: String?, content: [[String: Any]]) -> String {
        let blocks = content.map { block in
            "{" + block.map { "\"\($0)\":\(jsonValue($1))" }.joined(separator: ",") + "}"
        }.joined(separator: ",")
        return """
        {"type":"user","timestamp":"2026-08-22T01:51:00Z","uuid":\(jsonValue(uuid)),\
        "message":{"role":"user","content":[\(blocks)]},"sessionId":"sess-1"}
        """
    }

    private func jsonValue(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let string = value as? String { return "\"\(string)\"" }
        if let number = value as? NSNumber { return "\(number)" }
        return "null"
    }
}
