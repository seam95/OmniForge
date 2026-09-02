import XCTest
@testable import OmniForge

/// WorkBuddy trace 摘要解析：traceId/sessionId 推导、时间自适应、cached 拆分、模型链。
final class WorkbuddyUsageProcessingTests: XCTestCase {

    private func decodeTrace(_ json: String) throws -> WorkbuddyTraceDocument {
        try JSONDecoder().decode(WorkbuddyTraceDocument.self, from: Data(json.utf8))
    }

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
        XCTAssertNil(WorkbuddyUsageProcessing.traceUsage(from: nil, fallbackModel: "auto", fileURL: URL(fileURLWithPath: "/x/t.json")))
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
}