import XCTest
@testable import OmniForge

/// 聚合模型 ID 编解码：保留前缀不撞真实模型名、首个分隔符切开（模型名可含分隔符）、
/// 1M 标记大小写不敏感、空 key/模型判 malformed。
final class AggregationModelIDTests: XCTestCase {
    func test_encode_claudeShape() {
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeCode, key: "kimi", model: "k3", oneM: false),
                       "ccs-claude-kimi--k3")
    }

    func test_encode_claudeAppendsOneMMarkerWhenOneM() {
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeCode, key: "zhipu", model: "glm-5.2", oneM: true),
                       "ccs-claude-zhipu--glm-5.2[1M]")
    }

    func test_encode_codexShape() {
        XCTAssertEqual(AggregationModelID.encode(tool: .codex, key: "kimi", model: "kimi-k3", oneM: false),
                       "ccs-kimi/kimi-k3")
    }

    func test_decode_plainModelNameIsNotTouched() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "claude-sonnet-4-6"), .plain)
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "gpt-5.5"), .plain)
    }

    func test_decode_splitsAtFirstSeparatorSoModelNameMayContainSeparators() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "ccs-claude-kimi--k3--v2"),
                       .stack(key: "kimi", model: "k3--v2", oneM: false))
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "ccs-ds/openai/deepseek-v4"),
                       .stack(key: "ds", model: "openai/deepseek-v4", oneM: false))
    }

    func test_decode_recognizesOneMMarkerCaseInsensitively() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "ccs-claude-zhipu--glm-5.2[1m]"),
                       .stack(key: "zhipu", model: "glm-5.2", oneM: true))
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "ccs-claude-zhipu--glm-5.2[1M]"),
                       .stack(key: "zhipu", model: "glm-5.2", oneM: true))
    }

    func test_decode_malformedWhenKeyOrModelEmpty() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "ccs-claude---k3"), .malformed)
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "ccs-/k3"), .malformed)
    }

    func test_decode_codexIdWithoutSlashIsPlain() {
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "ccs-kimi"), .plain)
    }

    func test_claudePrefixContainsClaudeButDoesNotStartWithClaudeDash() {
        XCTAssertTrue(AggregationModelID.claudePrefix.contains("claude"))
        XCTAssertFalse(AggregationModelID.claudePrefix.hasPrefix("claude-"))
    }
}
