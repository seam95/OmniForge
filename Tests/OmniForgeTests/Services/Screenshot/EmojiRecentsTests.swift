import XCTest
@testable import OmniForge

/// 纯数据逻辑测试：EmojiRecents 的 choices/promoted 函数。
/// 无 @MainActor，无 AppKit 依赖。
final class EmojiRecentsTests: XCTestCase {

    // MARK: - choices(from:)

    func test_choices_emptyStorage_returnsDefaults() {
        let result = EmojiRecents.choices(from: [])
        XCTAssertEqual(result.count, EmojiRecents.limit,
                       "空存储应补足到 defaultRecent 的 limit 项")
        XCTAssertEqual(result, EmojiRecents.defaultRecent,
                       "空存储应直接返回默认列表")
    }

    func test_choices_dedupesAndPreservesOrder() {
        // 重复项只保留第一次出现
        let result = EmojiRecents.choices(from: ["🚀", "🚀", "❤️"])
        XCTAssertEqual(result.first, "🚀")
        XCTAssertEqual(result.prefix(3), ["🚀", "❤️", "⭐️"],
                       "去重后用 defaultRecent 补齐")
    }

    func test_choices_truncatesToLimit() {
        let many = (0..<20).map { _ in "✅" }
        let result = EmojiRecents.choices(from: many)
        XCTAssertEqual(result.count, EmojiRecents.limit,
                       "超过 limit 时应截断")
    }

    func test_choices_storedItemsBeforeDefaults() {
        let result = EmojiRecents.choices(from: ["🎉"])
        XCTAssertEqual(result.first, "🎉", "存储项在先")
        XCTAssertTrue(result.contains("⭐️"), "默认项补齐")
    }

    func test_choices_skipsEmptyStrings() {
        let result = EmojiRecents.choices(from: ["", "🚀", ""])
        XCTAssertTrue(result.contains("🚀"),
                      "空字符串应被跳过")
    }

    // MARK: - promoted(_:from:)

    func test_promoted_newEmoji_goesFirst() {
        let result = EmojiRecents.promoted("🎉", from: ["🚀"])
        XCTAssertEqual(result.first, "🎉", "新 emoji 置顶")
        XCTAssertTrue(result.contains("🚀"), "原有项保留")
        XCTAssertEqual(result.count, EmojiRecents.limit,
                       "结果长度 = limit")
    }

    func test_promoted_existingEmoji_movesToFront() {
        let result = EmojiRecents.promoted("🚀", from: ["🚀", "❤️"])
        XCTAssertEqual(result.first, "🚀", "已存在的 emoji 移到首位")
        XCTAssertTrue(result.contains("❤️"))
        // 不应出现重复
        let occurrences = result.filter { $0 == "🚀" }.count
        XCTAssertEqual(occurrences, 1, "emoji 不重复")
    }

    func test_promoted_fillsToLimitWithDefaults() {
        let result = EmojiRecents.promoted("🎉", from: [])
        XCTAssertEqual(result.count, EmojiRecents.limit,
                       "从空列表 promote 后长度 = limit")
        XCTAssertTrue(result.contains("🎉"))
        // 剩余位由 defaultRecent 补齐
        for defaultEmoji in EmojiRecents.defaultRecent.prefix(EmojiRecents.limit - 1) {
            XCTAssertTrue(result.contains(defaultEmoji),
                          "应包含默认项 '\(defaultEmoji)'")
        }
    }

    func test_promoted_isIdempotentWrtDedup() {
        // 重复 promote 同一个不应出现重复
        let a = EmojiRecents.promoted("🔥", from: [])
        let b = EmojiRecents.promoted("🔥", from: a)
        let count = b.filter { $0 == "🔥" }.count
        XCTAssertEqual(count, 1, "promote 同一 emoji 两次不重复")
    }
}
