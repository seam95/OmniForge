import XCTest
@testable import OmniForge

/// WorkBuddy trace 摘要解析：traceId/sessionId 推导、时间自适应（数字/ISO8601）、
/// cached 拆分、模型链（requestModelId 恢复）、六列减法。
final class WorkbuddyUsageProcessingTests: XCTestCase {

    private func decodeTrace(_ json: String) throws -> WorkbuddyTraceDocument {
        try JSONDecoder().decode(WorkbuddyTraceDocument.self, from: Data(json.utf8))
    }

    private func rawUsage(
        prompt: Int = 0,
        completion: Int = 0,
        cacheCreation: Int? = nil,
        promptCacheHit: Int? = nil,
        promptCacheWrite: Int? = nil,
        reasoning: Int? = nil
    ) -> ClaudeForkTranscriptEntry.ProviderData.RawUsage {
        ClaudeForkTranscriptEntry.ProviderData.RawUsage(
            promptTokens: prompt,
            completionTokens: completion,
            cacheReadInputTokens: nil,
            cacheCreationInputTokens: cacheCreation,
            promptCacheHitTokens: promptCacheHit,
            promptCacheWriteTokens: promptCacheWrite,
            promptTokensDetails: .init(cachedTokens: nil, reasoningTokens: nil),
            completionTokensDetails: .init(cachedTokens: nil, reasoningTokens: reasoning)
        )
    }

    // MARK: - trace 解析

    func test_traceUsage_splitsCachedFromInput() throws {
        let doc = try decodeTrace("""
        {"trace":{"traceId":"t-1","sessionId":"s-1","startedAt":1784502000000,\
        "modelInfo":{"totalInputTokens":1000,"totalOutputTokens":200,"totalCachedTokens":300,"models":["deepseek-v4"]}}}
        """)
        let usage = WorkbuddyUsageProcessing.traceUsage(
            from: doc, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/trace_1.json")
        )
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.traceId, "t-1")
        XCTAssertEqual(usage?.sessionId, "s-1")
        XCTAssertEqual(usage?.model, "deepseek-v4")
        XCTAssertEqual(usage?.usage.inputTokens, 700, "totalInput 含缓存 → 拆分")
        XCTAssertEqual(usage?.usage.cachedInputTokens, 300)
        XCTAssertEqual(usage?.usage.outputTokens, 200)
        XCTAssertEqual(usage?.usage.totalTokens, 900, "缓存不计入总量")
    }

    func test_traceUsage_secondsTimestampAdaptive() throws {
        let doc = try decodeTrace("""
        {"trace":{"traceId":"t-1","startedAt":1784502000,\
        "modelInfo":{"totalInputTokens":100,"totalOutputTokens":10}}}
        """)
        let usage = WorkbuddyUsageProcessing.traceUsage(
            from: doc, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/trace_1.json")
        )
        XCTAssertEqual(usage?.timestampMs, 1_784_502_000_000, "秒 → 毫秒自适应")
        XCTAssertEqual(usage?.sessionId, "t-1", "无 sessionId → traceId 兜底")
    }

    func test_traceUsage_iso8601StringTimestamp() throws {
        // 本机真实 trace 的 startedAt 为 ISO8601 字符串（2026-09 数据）。
        let doc = try decodeTrace("""
        {"trace":{"traceId":"t-1","sessionId":"s-1","startedAt":"2026-09-23T06:06:19.706Z",\
        "modelInfo":{"totalInputTokens":100,"totalOutputTokens":10}}}
        """)
        let usage = WorkbuddyUsageProcessing.traceUsage(
            from: doc, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/trace_1.json")
        )
        XCTAssertEqual(usage?.timestampMs, 1_790_143_579_706, "ISO8601 字符串 → epoch 毫秒")
    }

    func test_traceUsage_modelFallbackChain() throws {
        let doc = try decodeTrace("""
        {"trace":{"traceId":"t-1","startedAt":1784502000000,"metadata":{"sessionId":"meta-s",\
        "modelInfo":{"totalInputTokens":50,"totalOutputTokens":5,"model":"fallback-model"}}}}
        """)
        let usage = WorkbuddyUsageProcessing.traceUsage(
            from: doc, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/trace_1.json")
        )
        XCTAssertEqual(usage?.sessionId, "meta-s")
        XCTAssertEqual(usage?.model, "fallback-model", "metadata.modelInfo 兜底 + model 字段")
    }

    func test_traceUsage_nilWithoutTimestampOrTotals() throws {
        let noTime = try decodeTrace("""
        {"trace":{"traceId":"t-1","modelInfo":{"totalInputTokens":50,"totalOutputTokens":5}}}
        """)
        XCTAssertNil(WorkbuddyUsageProcessing.traceUsage(
            from: noTime, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/trace_1.json")
        ))
        let zeroTotals = try decodeTrace("""
        {"trace":{"traceId":"t-1","startedAt":1784502000000,"modelInfo":{"totalInputTokens":0,"totalOutputTokens":0}}}
        """)
        XCTAssertNil(WorkbuddyUsageProcessing.traceUsage(
            from: zeroTotals, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/trace_1.json")
        ))
        XCTAssertNil(WorkbuddyUsageProcessing.traceUsage(
            from: nil, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/t.json")
        ))
    }

    func test_traceUsage_fallbackTraceIdFromFilename() throws {
        let doc = try decodeTrace("""
        {"trace":{"startedAt":1784502000000,"modelInfo":{"totalInputTokens":5,"totalOutputTokens":1}}}
        """)
        let usage = WorkbuddyUsageProcessing.traceUsage(
            from: doc, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/traces/42/trace_abc.json")
        )
        XCTAssertEqual(usage?.traceId, "trace_abc", "traceId 缺失 → 文件名兜底")
    }

    // MARK: - rawUsage 归一化（共享 Claude-fork 核心适配）

    func test_tokenUsage_cacheMirrorsAndReasoningSplit() {
        let usage = WorkbuddyUsageProcessing.tokenUsage(from: rawUsage(
            prompt: 1000,
            completion: 300,
            cacheCreation: 50,
            promptCacheHit: 200,
            promptCacheWrite: 50,
            reasoning: 30
        ))
        XCTAssertEqual(usage?.inputTokens, 750, "1000 - 缓存读 200 - 缓存写 50")
        XCTAssertEqual(usage?.cachedInputTokens, 200)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 50)
        XCTAssertEqual(usage?.outputTokens, 270, "completion 含 reasoning → 拆分")
        XCTAssertEqual(usage?.reasoningOutputTokens, 30)
        XCTAssertEqual(usage?.totalTokens, 750 + 270 + 30, "缓存读写不计入总量")
        XCTAssertNil(WorkbuddyUsageProcessing.tokenUsage(from: rawUsage()))
        XCTAssertNil(WorkbuddyUsageProcessing.tokenUsage(from: nil))
    }

    // MARK: - 模型链（旧 WorkBuddy requestModelId 优先级）

    func test_modelName_requestModelIdFallbackBeforeEntryModel() {
        let providerOnlyRequest = ClaudeForkTranscriptEntry.ProviderData(
            messageId: "m", model: nil, requestModelId: "request-model", rawUsage: nil
        )
        XCTAssertEqual(
            WorkbuddyUsageProcessing.modelName(
                provider: providerOnlyRequest, entryModel: "row-model", fallback: "auto"
            ),
            "request-model",
            "providerData.model 缺失时 requestModelId 优先于行级 model"
        )
        let providerModel = ClaudeForkTranscriptEntry.ProviderData(
            messageId: "m", model: "provider-model", requestModelId: "request-model", rawUsage: nil
        )
        XCTAssertEqual(
            WorkbuddyUsageProcessing.modelName(
                provider: providerModel, entryModel: "row-model", fallback: "auto"
            ),
            "provider-model"
        )
        XCTAssertEqual(
            WorkbuddyUsageProcessing.modelName(provider: nil, entryModel: "row-model", fallback: "auto"),
            "row-model"
        )
        XCTAssertEqual(
            WorkbuddyUsageProcessing.modelName(provider: nil, entryModel: nil, fallback: "auto"),
            "auto"
        )
    }

    // MARK: - 去重 key / 时间桶

    func test_deduplicationKey_usesWorkbuddyPrefix() {
        XCTAssertEqual(
            WorkbuddyUsageProcessing.deduplicationKey(
                messageId: "m1", uuid: "u1", id: "i1", sessionId: "s1", timestampMs: 100
            ),
            "workbuddy:m1"
        )
        XCTAssertEqual(
            WorkbuddyUsageProcessing.deduplicationKey(
                messageId: nil, uuid: nil, id: nil, sessionId: "s1", timestampMs: 100
            ),
            "workbuddy:s1:100"
        )
    }

    func test_bucketStart_roundsToHalfHour() {
        let start = WorkbuddyUsageProcessing.bucketStart(fromMilliseconds: 1_784_502_600_000)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_784_502_000))
        XCTAssertNil(WorkbuddyUsageProcessing.bucketStart(fromMilliseconds: nil))
    }
}
