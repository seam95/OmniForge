import XCTest
@testable import OmniForge

/// 聚合模型 ID 编解码：保留前缀不撞真实模型名、首个分隔符切开（模型名可含分隔符）、
/// 1M 标记大小写不敏感、空 key/模型判 malformed。
final class AggregationModelIDTests: XCTestCase {
    func test_encode_claudeShape() {
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeCode, key: "kimi", model: "k3", oneM: false),
                       "om-claude-kimi--k3")
    }

    func test_encode_claudeAppendsOneMMarkerWhenOneM() {
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeCode, key: "zhipu", model: "glm-5.2", oneM: true),
                       "om-claude-zhipu--glm-5.2[1M]")
    }

    func test_encode_codexShape() {
        XCTAssertEqual(AggregationModelID.encode(tool: .codex, key: "kimi", model: "kimi-k3", oneM: false),
                       "om-kimi/kimi-k3")
    }

    func test_decode_plainModelNameIsNotTouched() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "claude-sonnet-4-6"), .plain)
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "gpt-5.5"), .plain)
    }

    func test_decode_splitsAtFirstSeparatorSoModelNameMayContainSeparators() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "om-claude-kimi--k3--v2"),
                       .stack(key: "kimi", model: "k3--v2", oneM: false))
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "om-ds/openai/deepseek-v4"),
                       .stack(key: "ds", model: "openai/deepseek-v4", oneM: false))
    }

    func test_decode_recognizesOneMMarkerCaseInsensitively() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "om-claude-zhipu--glm-5.2[1m]"),
                       .stack(key: "zhipu", model: "glm-5.2", oneM: true))
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "om-claude-zhipu--glm-5.2[1M]"),
                       .stack(key: "zhipu", model: "glm-5.2", oneM: true))
    }

    func test_decode_malformedWhenKeyOrModelEmpty() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeCode, id: "om-claude---k3"), .malformed)
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "om-/k3"), .malformed)
    }

    func test_decode_codexIdWithoutSlashIsPlain() {
        XCTAssertEqual(AggregationModelID.decode(tool: .codex, id: "om-kimi"), .plain)
    }

    func test_claudePrefixContainsClaudeButDoesNotStartWithClaudeDash() {
        XCTAssertTrue(AggregationModelID.claudePrefix.contains("claude"))
        XCTAssertFalse(AggregationModelID.claudePrefix.hasPrefix("claude-"))
    }

    // MARK: - Desktop（FNV-1a u64 编码；参考值由独立 Python 实现算出）

    func test_encode_desktopUsesFNV1aReferenceValues() {
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeDesktop, key: "kimi", model: "k3", oneM: false),
                       "claude-fable-om-136067")
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeDesktop, key: "zhipu", model: "glm-5.3", oneM: false),
                       "claude-fable-om-440626")
    }

    func test_encode_desktopPadsShortHashToSixDigits() {
        // 42660 < 100000 → 必须左补零为 042660。
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeDesktop, key: "glm", model: "deepseek-v4-pro", oneM: false),
                       "claude-fable-om-042660")
    }

    func test_encode_desktopIgnoresOneMFlag() {
        // Desktop 的 1M 语义在 route 的 supports1M，不进 id；oneM 参数对 Desktop 无效。
        XCTAssertEqual(AggregationModelID.encode(tool: .claudeDesktop, key: "kimi", model: "k3", oneM: true),
                       AggregationModelID.encode(tool: .claudeDesktop, key: "kimi", model: "k3", oneM: false))
    }

    func test_decode_desktopStackIDCarriesOriginalID() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: "claude-fable-om-136067"),
                       .stackCode("claude-fable-om-136067"))
    }

    /// 审查回归锁：profile 写了 prefer1m 后 Desktop 发 `<id>[1m]`，
    /// 解码必须先剥标记再校验 6 位数字，否则发布表查不到 → 1M 模型全 400。
    func test_decode_desktopStripsOneMMarkerFromStackID() {
        let id = AggregationModelID.encode(tool: .claudeDesktop, key: "kimi", model: "k3", oneM: false)
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: id + "[1m]"),
                       .stackCode(id))
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: id + "[1M]"),
                       .stackCode(id))
    }

    func test_decode_desktopMalformedWhenCodeIsNotSixDigits() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: "claude-fable-om-12"), .malformed)
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: "claude-fable-om-abcdef"), .malformed)
    }

    func test_decode_desktopNonStackIDIsPlain() {
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: "claude-sonnet-5"), .plain)
        XCTAssertEqual(AggregationModelID.decode(tool: .claudeDesktop, id: "glm-5.3"), .plain)
    }
}
