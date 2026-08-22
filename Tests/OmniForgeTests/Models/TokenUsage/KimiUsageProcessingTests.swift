import Foundation
import XCTest
@testable import OmniForge

/// Kimi wire.jsonl 解析归一化 — 纯函数：三种 usage 形状归一化（Anthropic / OpenAI 兼容 /
/// camelCase + 旧版 StatusUpdate）、cached 减法、去重 key、半小时桶、模型名清洗。
final class KimiUsageProcessingTests: XCTestCase {

    private func snakeUsage(_ dict: [String: Any]) -> KimiWireTokenUsage {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(KimiWireTokenUsage.self, from: data)
    }

    private func camelUsage(_ dict: [String: Any]) -> KimiWireTokenUsage {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(KimiWireTokenUsage.self, from: data)
    }

    // MARK: - 六列归一化

    func test_normalized_anthropicStyle_keepsInputWithSeparateCacheRead() {
        // 参考 parseKimiCodeIncremental：Anthropic 形状 cache_read 独立于 input（不减法）。
        let usage = snakeUsage([
            "input_tokens": 9000, "output_tokens": 250,
            "cache_read_input_tokens": 8000, "cache_creation_input_tokens": 100,
        ])
        let normalized = KimiUsageProcessing.normalized(from: usage)
        XCTAssertEqual(normalized?.inputTokens, 9000, "Anthropic 口径 input 已是纯非缓存输入")
        XCTAssertEqual(normalized?.cachedInputTokens, 8000)
        XCTAssertEqual(normalized?.cacheCreationInputTokens, 100)
        XCTAssertEqual(normalized?.outputTokens, 250)
        XCTAssertEqual(normalized?.reasoningOutputTokens, 0)
        XCTAssertEqual(normalized?.totalTokens, 9000 + 8000 + 100 + 250, "total 四列之和")
    }

    func test_normalized_openAICompat_subtractsCachedFromInput() {
        // 参考 parseKimiCodeIncremental OpenAI 兼容：cached 折叠进 input_tokens → 减法。
        let usage = snakeUsage([
            "input_tokens": 5000, "output_tokens": 120,
            "input_tokens_details": ["cached_tokens": 4000],
        ])
        let normalized = KimiUsageProcessing.normalized(from: usage)
        XCTAssertEqual(normalized?.inputTokens, 1000, "5000 - 4000 cached")
        XCTAssertEqual(normalized?.cachedInputTokens, 4000)
        XCTAssertEqual(normalized?.outputTokens, 120)
    }

    func test_normalized_camelCase_inputOtherIsFreshInput() {
        // 参考 parseKimiCodeIncremental camelCase（kimi-code 0.6.0+）：inputOther 为纯输入。
        let usage = camelUsage([
            "inputOther": 1500, "inputCacheRead": 8000, "inputCacheCreation": 100, "output": 250,
        ])
        let normalized = KimiUsageProcessing.normalized(from: usage)
        XCTAssertEqual(normalized?.inputTokens, 1500, "camelCase 不再是减法口径")
        XCTAssertEqual(normalized?.cachedInputTokens, 8000)
        XCTAssertEqual(normalized?.cacheCreationInputTokens, 100)
        XCTAssertEqual(normalized?.outputTokens, 250)
        XCTAssertEqual(normalized?.totalTokens, 1500 + 8000 + 100 + 250)
    }

    func test_normalized_legacyStatusUpdate_mapsSnakeFields() {
        // 旧版 kimi-cli StatusUpdate：input_other / input_cache_read / input_cache_creation。
        let usage = snakeUsage([
            "input_other": 14218, "output": 123, "input_cache_read": 6144, "input_cache_creation": 0,
        ])
        let normalized = KimiUsageProcessing.normalized(from: usage)
        XCTAssertEqual(normalized?.inputTokens, 14218)
        XCTAssertEqual(normalized?.cachedInputTokens, 6144)
        XCTAssertEqual(normalized?.outputTokens, 123)
        XCTAssertEqual(normalized?.totalTokens, 14218 + 6144 + 123)
    }

    func test_normalized_emptyOrZero_returnsNil() {
        XCTAssertNil(KimiUsageProcessing.normalized(from: KimiWireTokenUsage()))
        XCTAssertNil(KimiUsageProcessing.normalized(from: snakeUsage(["input_tokens": 0, "output_tokens": 0])))
    }

    func test_normalized_negativeFields_areClamped() {
        let normalized = KimiUsageProcessing.normalized(from: snakeUsage([
            "input_tokens": -50, "output_tokens": 10,
        ]))
        XCTAssertEqual(normalized?.inputTokens, 0)
        XCTAssertEqual(normalized?.outputTokens, 10)
    }

    // MARK: - 去重 key

    func test_eventKey_stepEndAndStatusUpdateNamespaces() {
        XCTAssertEqual(KimiUsageProcessing.eventKey(shape: .stepEnd, id: "se1"), "kimi-code:se1")
        XCTAssertEqual(KimiUsageProcessing.eventKey(shape: .statusUpdate, id: "chatcmpl-TEST1"), "kimi:chatcmpl-TEST1")
        XCTAssertNil(KimiUsageProcessing.eventKey(shape: .stepEnd, id: nil), "无 uuid 不可去重 → 跳过")
        XCTAssertNil(KimiUsageProcessing.eventKey(shape: .statusUpdate, id: ""))
    }

    // MARK: - 时间桶

    func test_bucketStart_fromMilliseconds_kimiCode() {
        // `time` 为 epoch 毫秒（kimi-code 0.6+）。
        let start = KimiUsageProcessing.bucketStart(fromMilliseconds: 1_780_000_001_000)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_779_998_400), "毫秒 → 小时桶对齐")
        XCTAssertNil(KimiUsageProcessing.bucketStart(fromMilliseconds: nil))
        XCTAssertNil(KimiUsageProcessing.bucketStart(fromMilliseconds: 0))
    }

    func test_bucketStart_fromSeconds_legacyTimestamp() {
        let start = KimiUsageProcessing.bucketStart(fromSeconds: 1_775_833_108)
        XCTAssertEqual(start, Date(timeIntervalSince1970: Double((1_775_833_108 / 1800) * 1800)),
                       "旧版 timestamp 为秒（可含小数）")
        XCTAssertNil(KimiUsageProcessing.bucketStart(fromSeconds: nil))
    }

    // MARK: - 模型名

    func test_modelName_stripsKimiCodePrefix() {
        XCTAssertEqual(KimiUsageProcessing.modelName(fromAlias: "kimi-code/kimi-k2.6"), "kimi-k2.6")
        XCTAssertEqual(KimiUsageProcessing.modelName(fromAlias: "kimi-k2.6"), "kimi-k2.6")
        XCTAssertNil(KimiUsageProcessing.modelName(fromAlias: nil), "无 alias 保持现状")
        XCTAssertNil(KimiUsageProcessing.modelName(fromAlias: ""))
    }
}
