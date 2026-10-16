import XCTest
@testable import OmniForge

/// 成员兼容开关合并（对齐 cc-switch `controller.rs:256-327` `with_member_switches`）：
/// ANY 组任一成员要关就关（取第一个要关成员的原值）、ALL 组只删不插（全部显式开才保留）、
/// 值解析三态、默认那家作底子、`others` 为空整个合并不执行。
final class AggregationSwitchMergerTests: XCTestCase {
    private func member(_ id: String, extra: [String: String]) -> ProviderProfile {
        ProviderProfile(id: id, name: id, tool: .claudeCode, baseURL: "https://x.example", token: "sk", extraEnv: extra)
    }

    func test_merges_anyGroupOnWhenAnyOtherMemberDisables() {
        // ANY 组：默认那家作底子；非默认成员第一个"要关"的原值覆盖（cc-switch asks_to_turn_off）
        let out = AggregationSwitchMerger.mergedValues(
            defaultProfile: member("a", extra: [:]),
            others: [member("b", extra: ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "true"])])
        XCTAssertEqual(out["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"], "true")
    }

    func test_merges_anyGroupKeepsDefaultWhenDefaultAlreadyAsksOff() {
        // 默认那家已"要关"→ 保持默认的值，不被成员覆盖
        let out = AggregationSwitchMerger.mergedValues(
            defaultProfile: member("a", extra: ["CLAUDE_CODE_DISABLE_ARTIFACT": "true"]),
            others: [member("b", extra: ["CLAUDE_CODE_DISABLE_ARTIFACT": "false"])])
        XCTAssertEqual(out["CLAUDE_CODE_DISABLE_ARTIFACT"], "true")
    }

    func test_merges_anyGroupAutoModeServerOffMeansFalse() {
        let out = AggregationSwitchMerger.mergedValues(
            defaultProfile: member("a", extra: [:]),
            others: [member("b", extra: ["CLAUDE_CODE_AUTO_MODE_SERVER": "false"])])
        XCTAssertEqual(out["CLAUDE_CODE_AUTO_MODE_SERVER"], "false")
    }

    func test_merges_allGroupKeptOnlyWhenEveryOtherMemberOptedIn() {
        let on = ["ENABLE_TOOL_SEARCH": "1", "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "yes", "CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING": "on"]
        let kept = AggregationSwitchMerger.mergedValues(defaultProfile: member("a", extra: on), others: [member("b", extra: on)])
        XCTAssertEqual(kept["ENABLE_TOOL_SEARCH"], "1", "保留=默认那家投影里的既有值（cc-switch ALL 组只删不插）")

        let dropped = AggregationSwitchMerger.mergedValues(
            defaultProfile: member("a", extra: on),
            others: [member("b", extra: ["ENABLE_TOOL_SEARCH": "1", "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT": "yes"])])
        XCTAssertNil(dropped["CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING"], "任一非默认成员没开就删")
    }

    func test_merges_noOthersKeepsDefaultAsIs() {
        // 只有默认一家（others 空）→ 合并不执行，默认的开关原样保留
        let out = AggregationSwitchMerger.mergedValues(
            defaultProfile: member("a", extra: ["ENABLE_TOOL_SEARCH": "1"]),
            others: [])
        XCTAssertEqual(out["ENABLE_TOOL_SEARCH"], "1")
    }

    func test_switchValueParsing_isThreeValuedLikeCcSwitch() {
        // 字符串 1/true/yes/on 开；0/false/no/off/空 关；其他 → 不可解析（ANY 组跳过该成员、ALL 组按未开）
        XCTAssertEqual(AggregationSwitchMerger.switchValue("TRUE"), .on)
        XCTAssertEqual(AggregationSwitchMerger.switchValue("off"), .off)
        XCTAssertEqual(AggregationSwitchMerger.switchValue(""), .off)
        XCTAssertEqual(AggregationSwitchMerger.switchValue("banana"), .unparseable)

        // 不可解析的 ANY 值不算"要关"：AUTO_MODE_SERVER=banana 的成员被跳过
        let out = AggregationSwitchMerger.mergedValues(
            defaultProfile: member("a", extra: [:]),
            others: [member("b", extra: ["CLAUDE_CODE_AUTO_MODE_SERVER": "banana"])])
        XCTAssertNil(out["CLAUDE_CODE_AUTO_MODE_SERVER"])
    }
}
