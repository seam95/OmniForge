import XCTest
@testable import OmniForge

/// 输入法组合态（marked text）回调：占位符显隐与回写守卫的依据。
/// 组合态期间 textDidChange 不回调，SwiftUI 侧只能靠这三个入口上报的状态。
@MainActor
final class StickyNoteTextViewTests: XCTestCase {

    func test_setMarkedText_reportsMarkedStateEntered() {
        let textView = StickyNoteActivatableTextView(frame: .zero)
        var reported: [Bool] = []
        textView.onMarkedStateChanged = { reported.append($0) }

        // 模拟拼音组合：setMarkedText 插入未确认的组合串。
        textView.setMarkedText("s'da'da", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: 0, length: 0))

        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(reported.last, true, "进入组合态必须上报 true，占位符随之隐藏")
    }

    func test_setMarkedText_withEmptyString_reportsMarkedStateExited() {
        let textView = StickyNoteActivatableTextView(frame: .zero)
        var reported: [Bool] = []
        textView.onMarkedStateChanged = { reported.append($0) }
        textView.setMarkedText("s'da", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 0))

        // 取消组合（Esc）：以空串调 setMarkedText。
        textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: 0))

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(reported.last, false, "取消组合必须上报 false，占位符按内容是否为空恢复")
    }

    func test_unmarkText_reportsMarkedStateExited() {
        let textView = StickyNoteActivatableTextView(frame: .zero)
        var reported: [Bool] = []
        textView.onMarkedStateChanged = { reported.append($0) }
        textView.setMarkedText("s'da", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 0))

        textView.unmarkText()

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(reported.last, false)
    }

    func test_insertText_reportsMarkedStateExited() {
        let textView = StickyNoteActivatableTextView(frame: .zero)
        var reported: [Bool] = []
        textView.onMarkedStateChanged = { reported.append($0) }
        textView.setMarkedText("s'da", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 0))

        // 候选确认上屏：组合串被确认文本替换，组合态结束。
        textView.insertText("是哒", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(reported.last, false, "确认上屏必须上报 false，占位符按内容是否为空恢复")
    }
}
