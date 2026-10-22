import XCTest
@testable import OmniForge

/// Qoder CN Claude 兼容行解析：六列口径、reasoning 拆分、模型链、会话归属与去重 key。
final class QoderCNUsageProcessingTests: XCTestCase {

    private func decodeEntry(_ json: String) throws -> QoderCNTranscriptEntry {
        try JSONDecoder().decode(QoderCNTranscriptEntry.self, from: Data(json.utf8))
    }

    private func assistantEntry(
        usage: String,
        model: String = "qwen3-coder-plus",
        messageId: String = "m1",
        sessionId: String = "s1"
    ) throws -> QoderCNTranscriptEntry {
        try decodeEntry("""
        {"type":"assistant","sessionId":"\(sessionId)","timestamp":"2026-09-23T06:06:19.706Z",\
        "message":{"id":"\(messageId)","model":"\(model)","usage":\(usage)}}
        """)
    }

    // MARK: - 六列归一化

    func test_tokenUsage_claudeColumns() throws {
        let entry = try assistantEntry(usage: """
        {"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_read_input_tokens":200}
        """)
        let usage = QoderCNUsageProcessing.tokenUsage(from: entry)
        XCTAssertEqual(usage?.inputTokens, 100)
        XCTAssertEqual(usage?.cachedInputTokens, 200)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 30)
        XCTAssertEqual(usage?.outputTokens, 50)
        XCTAssertEqual(usage?.reasoningOutputTokens, 0)
        XCTAssertEqual(usage?.totalTokens, 150, "缓存读写不计入总量")
    }

    func test_tokenUsage_rootUsageFallback() throws {
        let entry = try decodeEntry("""
        {"type":"assistant","timestamp":"2026-09-23T06:06:19.706Z",\
        "usage":{"input_tokens":10,"output_tokens":5}}
        """)
        XCTAssertEqual(QoderCNUsageProcessing.tokenUsage(from: entry)?.totalTokens, 15)
    }

    func test_tokenUsage_reasoningSplitKeepsTotal() throws {
        let entry = try assistantEntry(usage: """
        {"input_tokens":100,"output_tokens":300,"reasoning_tokens":30}
        """)
        let usage = QoderCNUsageProcessing.tokenUsage(from: entry)
        XCTAssertEqual(usage?.outputTokens, 270, "reasoning 从 output 拆分")
        XCTAssertEqual(usage?.reasoningOutputTokens, 30)
        XCTAssertEqual(usage?.totalTokens, 400, "拆分不改变总量")
    }

    func test_tokenUsage_nilWhenZeroOrMissing() throws {
        let zero = try assistantEntry(usage: "{\"input_tokens\":0,\"output_tokens\":0}")
        XCTAssertNil(QoderCNUsageProcessing.tokenUsage(from: zero))
        let missing = try decodeEntry("{\"type\":\"assistant\",\"message\":{\"id\":\"m1\"}}")
        XCTAssertNil(QoderCNUsageProcessing.tokenUsage(from: missing))
    }

    // MARK: - 模型 / 时间

    func test_modelName_chain() {
        XCTAssertEqual(
            QoderCNUsageProcessing.modelName(messageModel: "qwen3-coder-plus", entryModel: "row-model"),
            "qwen3-coder-plus"
        )
        XCTAssertEqual(
            QoderCNUsageProcessing.modelName(messageModel: nil, entryModel: "row-model"),
            "row-model"
        )
        XCTAssertEqual(
            QoderCNUsageProcessing.modelName(messageModel: "  ", entryModel: nil),
            QoderCNUsageProcessing.defaultModel
        )
    }

    func test_bucketStart_iso8601ToHalfHour() {
        XCTAssertEqual(
            QoderCNUsageProcessing.bucketStart(from: "2026-09-23T06:06:19.706Z"),
            Date(timeIntervalSince1970: 1_790_143_200)
        )
        XCTAssertEqual(
            QoderCNUsageProcessing.bucketStart(from: "2026-09-23T06:06:19Z"),
            Date(timeIntervalSince1970: 1_790_143_200),
            "无小数秒也支持"
        )
        XCTAssertNil(QoderCNUsageProcessing.bucketStart(from: nil))
        XCTAssertNil(QoderCNUsageProcessing.bucketStart(from: "not-a-time"))
    }

    // MARK: - 会话归属

    func test_sessionID_prefersEntryThenFilePath() throws {
        let entry = try assistantEntry(usage: "{\"input_tokens\":1,\"output_tokens\":1}")
        XCTAssertEqual(
            QoderCNUsageProcessing.sessionID(
                from: entry, file: URL(fileURLWithPath: "/x/projects/enc/other.jsonl")
            ),
            "s1"
        )
        let noSession = try decodeEntry("{\"type\":\"assistant\"}")
        XCTAssertEqual(
            QoderCNUsageProcessing.sessionID(
                from: noSession, file: URL(fileURLWithPath: "/x/projects/enc/abc-123.jsonl")
            ),
            "abc-123",
            "主会话文件：文件名即 sessionId"
        )
        XCTAssertEqual(
            QoderCNUsageProcessing.sessionID(
                from: noSession,
                file: URL(fileURLWithPath: "/x/projects/enc/abc-123/subagents/agent-1.jsonl")
            ),
            "abc-123",
            "子代理文件：subagents 的上级目录即 sessionId"
        )
    }

    func test_isSubagentFile() {
        XCTAssertTrue(QoderCNUsageProcessing.isSubagentFile(
            URL(fileURLWithPath: "/x/projects/enc/sess/subagents/agent-1.jsonl")
        ))
        XCTAssertFalse(QoderCNUsageProcessing.isSubagentFile(
            URL(fileURLWithPath: "/x/projects/enc/sess.jsonl")
        ))
    }

    // MARK: - 去重 key

    func test_deduplicationKey_chainAndStableFallback() {
        let main = URL(fileURLWithPath: "/x/projects/enc/sess-1.jsonl")
        XCTAssertEqual(
            QoderCNUsageProcessing.deduplicationKey(
                sessionID: "sess-1", messageID: "m1", requestID: "r1", file: main, lineOffset: 0
            ),
            "qoder-cn:sess-1:m1",
            "message.id 优先"
        )
        XCTAssertEqual(
            QoderCNUsageProcessing.deduplicationKey(
                sessionID: "sess-1", messageID: nil, requestID: "r1", file: main, lineOffset: 0
            ),
            "qoder-cn:sess-1:r1"
        )
        let fallback = QoderCNUsageProcessing.deduplicationKey(
            sessionID: "sess-1", messageID: nil, requestID: nil, file: main, lineOffset: 128
        )
        XCTAssertEqual(fallback, "qoder-cn:sess-1:enc/sess-1.jsonl:B128")
        let subagent = URL(fileURLWithPath: "/x/projects/enc/sess-1/subagents/agent-1.jsonl")
        XCTAssertEqual(
            QoderCNUsageProcessing.deduplicationKey(
                sessionID: "sess-1", messageID: nil, requestID: nil, file: subagent, lineOffset: 64
            ),
            "qoder-cn:sess-1:subagents/agent-1.jsonl:B64",
            "兜底 key 含文件身份，主/子代理同 session 行号不碰撞"
        )
    }

    func test_userDeduplicationKey() {
        let file = URL(fileURLWithPath: "/x/projects/enc/sess-1.jsonl")
        XCTAssertEqual(
            QoderCNUsageProcessing.userDeduplicationKey(
                sessionID: "sess-1", uuid: "u-1", file: file, lineOffset: 0
            ),
            "qoder-cn:u:sess-1:u-1"
        )
        XCTAssertEqual(
            QoderCNUsageProcessing.userDeduplicationKey(
                sessionID: "sess-1", uuid: nil, file: file, lineOffset: 256
            ),
            "qoder-cn:u:sess-1:enc/sess-1.jsonl:B256",
            "无 uuid 时绝对偏移兜底"
        )
    }

    // MARK: - 隐私：content 只声明 type

    func test_contentBlock_decodesTypeOnly() throws {
        let entry = try decodeEntry("""
        {"type":"user","uuid":"u-1","message":{"content":[{"type":"text","text":"hello"},{"type":"tool_result"}]}}
        """)
        XCTAssertTrue(entry.message?.hasTextBlock == true)
        let toolOnly = try decodeEntry("""
        {"type":"user","uuid":"u-2","message":{"content":[{"type":"tool_result"}]}}
        """)
        XCTAssertFalse(toolOnly.message?.hasTextBlock == true)
    }
}
