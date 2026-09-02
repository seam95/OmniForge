import XCTest
@testable import OmniForge

/// dsh（DeepSeek Harness）session.jsonl 行解析 — 模型清洗 / 六列映射 / 半小时桶 / 去重 key。
final class DshUsageProcessingTests: XCTestCase {

    // MARK: - 模型名

    func test_normalizedModelName_stripsProviderPrefix() {
        XCTAssertEqual(DshUsageProcessing.normalizedModelName("deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(DshUsageProcessing.normalizedModelName("deepseek/deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertEqual(DshUsageProcessing.normalizedModelName("a/b/c-v2"), "c-v2")
        XCTAssertEqual(DshUsageProcessing.normalizedModelName("  deepseek-v4-flash  "), "deepseek-v4-flash")
        XCTAssertNil(DshUsageProcessing.normalizedModelName(nil))
        XCTAssertNil(DshUsageProcessing.normalizedModelName(""))
        XCTAssertNil(DshUsageProcessing.normalizedModelName("   "))
    }

    // MARK: - 六列映射

    func test_tokenUsage_mapsDisjointFieldsDirectly() {
        let usage = makeUsage(input: 100, output: 40, cacheRead: 10, cacheWrite: 5, reasoning: 3)
        let tokens = DshUsageProcessing.tokenUsage(from: usage)
        XCTAssertNotNil(tokens)
        XCTAssertEqual(tokens?.inputTokens, 100)
        XCTAssertEqual(tokens?.cachedInputTokens, 10, "cache_read 并入 cached 列")
        XCTAssertEqual(tokens?.cacheCreationInputTokens, 5, "cache_write 并入 cache_creation 列")
        XCTAssertEqual(tokens?.outputTokens, 40)
        XCTAssertEqual(tokens?.reasoningOutputTokens, 3)
        XCTAssertEqual(tokens?.totalTokens, 100 + 40 + 3, "total 为 input + output + reasoning（字段互斥）")
    }

    func test_tokenUsage_nilWhenAllZero() {
        XCTAssertNil(DshUsageProcessing.tokenUsage(from: makeUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)))
        XCTAssertNil(DshUsageProcessing.tokenUsage(from: nil))
    }

    // MARK: - 时间桶

    func test_bucketStart_fromEpochMilliseconds() {
        // 1_784_502_000 是 UTC 半小时边界：桶起点保持不变。
        let ms = 1_784_502_000.0 * 1000
        let start = DshUsageProcessing.bucketStart(fromMilliseconds: ms)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_784_502_000), "已在半小时边界")
    }

    func test_bucketStart_roundsDownToHalfHour() {
        // 边界 1_784_502_000 + 600s（:10 分）→ 回退到该半小时起点。
        let base = Date(timeIntervalSince1970: 1_784_502_600)
        let start = DshUsageProcessing.bucketStart(fromMilliseconds: base.timeIntervalSince1970 * 1000)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_784_502_000))
    }

    func test_bucketStart_nilForInvalid() {
        XCTAssertNil(DshUsageProcessing.bucketStart(fromMilliseconds: nil))
        XCTAssertNil(DshUsageProcessing.bucketStart(fromMilliseconds: 0))
        XCTAssertNil(DshUsageProcessing.bucketStart(fromMilliseconds: -5))
    }

    // MARK: - 去重 key

    func test_dedupKey_requiresBothSessionIdAndSeq() {
        XCTAssertEqual(DshUsageProcessing.deduplicationKey(sessionID: "sess-1", seq: 42), "dsh:sess-1:42")
        XCTAssertNil(DshUsageProcessing.deduplicationKey(sessionID: "sess-1", seq: nil))
        XCTAssertNil(DshUsageProcessing.deduplicationKey(sessionID: nil, seq: 42))
        XCTAssertNil(DshUsageProcessing.deduplicationKey(sessionID: "", seq: 42))
        XCTAssertNil(DshUsageProcessing.deduplicationKey(sessionID: "sess-1", seq: -1))
    }

    // MARK: - 行解码（隐私红线：正文不物化）

    func test_entry_decodeOnlyRoutesAndUsage() throws {
        let line = """
        {"type":"assistant/message","seq":7,"time":1784503500000,"data":{"message":{"source":{"model":"deepseek/deepseek-v4-pro"}},"usage":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":0,"cacheWriteTokens":0,"reasoningTokens":0}}}
        """
        let entry = try JSONDecoder().decode(DshTranscriptEntry.self, from: Data(line.utf8))
        XCTAssertEqual(entry.type, "assistant/message")
        XCTAssertEqual(entry.seq, 7)
        XCTAssertEqual(entry.time, 1_784_503_500_000)
        XCTAssertEqual(entry.data?.message?.source?.model, "deepseek/deepseek-v4-pro")
        XCTAssertEqual(entry.data?.usage?.inputTokens, 100)
    }

    private func makeUsage(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reasoning: Int
    ) -> DshTranscriptEntry.Data.Usage {
        DshTranscriptEntry.Data.Usage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning
        )
    }
}