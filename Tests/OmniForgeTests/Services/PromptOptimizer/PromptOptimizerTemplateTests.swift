import XCTest
@testable import OmniForge

/// 内置两段式模板的组装契约（功能规格附录 A）。
final class PromptOptimizerTemplateTests: XCTestCase {
    func test_compose_producesSystemThenUserMessages() {
        let messages = PromptOptimizerTemplate.compose(input: "写一个排序函数")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "system")
        XCTAssertEqual(messages[0].content, PromptOptimizerTemplate.systemPrompt)
        XCTAssertEqual(messages[1].role, "user")
    }

    func test_compose_substitutesInputPlaceholderInUserMessage() {
        let messages = PromptOptimizerTemplate.compose(input: "帮我优化这段")

        let expected = PromptOptimizerTemplate.userPromptTemplate.replacingOccurrences(
            of: "{input}",
            with: "帮我优化这段"
        )
        XCTAssertEqual(messages[1].content, expected)
        XCTAssertEqual(messages[1].content.contains("{input}"), false, "占位符必须被替换干净")
    }

    func test_compose_systemPromptContainsNoPlaceholder() {
        XCTAssertEqual(
            PromptOptimizerTemplate.systemPrompt.contains("{input}"),
            false,
            "system 段不含占位符（占位符仅存在于 user 模板）"
        )
    }

    func test_compose_inputWithSpecialCharactersSurvivesVerbatim() {
        // 选中文本是数据：引号 / 换行 / 反斜杠 / 占位符字面量都必须原样进入 user 消息。
        let tricky = "包含\"引号\"\n换行\\反斜杠 {input} 字面量"

        let messages = PromptOptimizerTemplate.compose(input: tricky)

        XCTAssertTrue(messages[1].content.contains(tricky), "特殊字符原样保留")
    }
}
