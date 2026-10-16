import XCTest
@testable import OmniForge

/// 聚合状态模型：两个工具各自独立（模式位/名单/登记簿三层互不影响），编解码忽略未知字段。
final class AggregationStackTests: XCTestCase {
    func test_codableRoundTrip_preservesBothToolStacks() throws {
        let claude = AggregationStack.ToolStack(enabled: true, members: ["kimi", "glm"], keys: ["kimi": "kimi", "glm": "glm"])
        let codex = AggregationStack.ToolStack(enabled: true, members: ["deepseek"], keys: ["deepseek": "deepseek"])
        let stack = AggregationStack(claudeCode: claude, codex: codex)
        XCTAssertEqual(try JSONDecoder().decode(AggregationStack.self, from: JSONEncoder().encode(stack)), stack)
    }

    func test_toolStacks_areIndependentPerTool() {
        var stack = AggregationStack()
        stack.setToolStack(.init(enabled: true, members: ["deepseek"], keys: ["deepseek": "deepseek"]), for: .codex)
        XCTAssertTrue(stack.toolStack(.codex).enabled)
        XCTAssertFalse(stack.toolStack(.claudeCode).enabled)
        XCTAssertTrue(stack.toolStack(.claudeCode).members.isEmpty)
    }

    func test_isMember_and_keyOf_liveOnToolStack() {
        let stack = AggregationStack(claudeCode: .init(members: ["kimi"], keys: ["kimi": "kimi"]))
        XCTAssertTrue(stack.toolStack(.claudeCode).isMember("kimi"))
        XCTAssertFalse(stack.toolStack(.claudeCode).isMember("glm"))
        XCTAssertEqual(stack.toolStack(.claudeCode).keyOf(profileID: "kimi"), "kimi")
        XCTAssertNil(stack.toolStack(.claudeCode).keyOf(profileID: "glm"))
        XCTAssertFalse(stack.toolStack(.codex).isMember("kimi"))
    }

    func test_decodingIgnoresUnknownFields() throws {
        let json = Data(#"{"claudeCode":{"enabled":true,"members":["a"],"keys":{"a":"a"},"futureField":1},"codex":{"enabled":false}}"#.utf8)
        let stack = try JSONDecoder().decode(AggregationStack.self, from: json)
        XCTAssertEqual(stack.toolStack(.claudeCode).members, ["a"])
    }
}
