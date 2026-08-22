import Foundation
import XCTest
@testable import OmniForge

/// Gemini 会话 JSON 解析归一化 — 纯函数：消息级累计差量 / 六列归一化（tool 并入 output、
/// total 重算含 cached）/ 去重 key / 半小时桶（参考 TokenTracker rollout-parser.test.js）。
final class GeminiUsageProcessingTests: XCTestCase {

    // MARK: - 六列归一化

    func test_normalized_mapsFields_toolMergedIntoOutput_totalRecomputed() {
        // 参考 parseGeminiIncremental：output 含 tool；Gemini 自报 total 不含 cached → 重算。
        let tokens = GeminiMessageTokens(input: 10, output: 5, cached: 20, thoughts: 3, tool: 2, total: 17)
        let usage = GeminiUsageProcessing.normalized(from: tokens)
        XCTAssertEqual(usage, TokenUsage(
            inputTokens: 10,
            cachedInputTokens: 20,
            cacheCreationInputTokens: 0,
            outputTokens: 7,
            reasoningOutputTokens: 3,
            totalTokens: 40
        ))
        XCTAssertEqual(usage?.totalTokens, 10 + 20 + 7 + 3, "total = input + cached + output(tool) + thoughts")
    }

    func test_normalized_zeroTotal_returnsNil() {
        XCTAssertNil(GeminiUsageProcessing.normalized(from: GeminiMessageTokens(input: 0, output: 0, cached: 0, thoughts: 0, tool: 0, total: 0)))
    }

    func test_normalized_negativeFields_areClamped() {
        let usage = GeminiUsageProcessing.normalized(from: GeminiMessageTokens(input: -1, output: 2, cached: 0, thoughts: 0, tool: 5, total: 6))
        XCTAssertEqual(usage?.inputTokens, 0, "负输入 clamp 到 0")
        XCTAssertEqual(usage?.outputTokens, 7, "output+tool")
    }

    // MARK: - 消息级累计差量

    func test_delta_firstMessage_usesCumulativeAsDelta() {
        let delta = GeminiUsageProcessing.delta(
            current: GeminiMessageTokens(input: 5, output: 1, cached: 0, thoughts: 0, tool: 0, total: 6),
            previous: nil
        )
        XCTAssertEqual(delta, GeminiMessageTokens(input: 5, output: 1, cached: 0, thoughts: 0, tool: 0, total: 6))
    }

    func test_delta_subtractsPreviousCumulative() {
        let delta = GeminiUsageProcessing.delta(
            current: GeminiMessageTokens(input: 9, output: 3, cached: 0, thoughts: 0, tool: 0, total: 12),
            previous: GeminiMessageTokens(input: 8, output: 2, cached: 0, thoughts: 0, tool: 0, total: 10)
        )
        XCTAssertEqual(delta, GeminiMessageTokens(input: 1, output: 1, cached: 0, thoughts: 0, tool: 0, total: 2))
    }

    func test_delta_duplicateCumulativeSnapshot_isZeroDelta() {
        let snapshot = GeminiMessageTokens(input: 5, output: 1, cached: 0, thoughts: 0, tool: 0, total: 6)
        let delta = GeminiUsageProcessing.delta(current: snapshot, previous: snapshot)
        XCTAssertEqual(delta, GeminiMessageTokens(input: 0, output: 0, cached: 0, thoughts: 0, tool: 0, total: 0))
        XCTAssertNil(delta.flatMap { GeminiUsageProcessing.normalized(from: $0) }, "零增量不产生计数")
    }

    func test_delta_cumulativeRollback_returnsNil() {
        // 累计回退（session JSON 重写/流轮换）→ 无法确定差量 → 保守跳过（对齐 isTotalsReset）。
        XCTAssertNil(GeminiUsageProcessing.delta(
            current: GeminiMessageTokens(input: 5, output: 1, cached: 0, thoughts: 0, tool: 0, total: 6),
            previous: GeminiMessageTokens(input: 8, output: 2, cached: 0, thoughts: 0, tool: 0, total: 10)
        ))
    }

    // MARK: - 去重 key

    func test_eventKey_requiresMessageID() {
        XCTAssertEqual(GeminiUsageProcessing.eventKey(messageID: "m1"), "gemini:m1")
        XCTAssertEqual(GeminiUsageProcessing.eventKey(messageID: "m-123"), "gemini:m-123")
        XCTAssertNil(GeminiUsageProcessing.eventKey(messageID: nil), "无消息 id 不可去重 → 跳过")
        XCTAssertNil(GeminiUsageProcessing.eventKey(messageID: ""))
    }

    // MARK: - 时间桶

    func test_bucketStart_isoTimestamp_toHalfHourUTC() {
        let start = GeminiUsageProcessing.bucketStart(from: "2025-12-26T08:05:00.000Z")
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_766_736_000), "08:05 → 08:00 UTC 半小时桶")
        XCTAssertNil(GeminiUsageProcessing.bucketStart(from: nil))
        XCTAssertNil(GeminiUsageProcessing.bucketStart(from: "not-a-date"))
    }

    // MARK: - 模型

    func test_modelName_fallback() {
        XCTAssertEqual(GeminiUsageProcessing.modelName("gemini-3-flash-preview"), "gemini-3-flash-preview")
        XCTAssertEqual(GeminiUsageProcessing.modelName("  "), GeminiUsageProcessing.defaultModel)
        XCTAssertEqual(GeminiUsageProcessing.modelName(nil), GeminiUsageProcessing.defaultModel)
    }
}
