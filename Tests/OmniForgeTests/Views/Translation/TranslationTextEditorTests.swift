import AppKit
import XCTest
@testable import OmniForge

/// 原文编辑区按键路径：⌘Return 提交、普通 Return 换行、Esc 让位输入法/系统弹层。
///
/// 自动化不构造真实输入法会话，通过 `markedTextProvider`/`modifierFlagsProvider`
/// 注入组合态与修饰符；真实中文候选窗交互留真机验收。
@MainActor
final class TranslationTextEditorTests: XCTestCase {
    private final class CallCounter {
        var submit = 0
        var escape = 0
        var markedText: [Bool] = []
    }

    private func makeTextView(
        modifiers: NSEvent.ModifierFlags = [],
        marked: @escaping () -> Bool = { false },
        counter: CallCounter
    ) -> TranslationInputTextView {
        let textView = TranslationInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.onSubmit = { counter.submit += 1 }
        textView.onEscape = { counter.escape += 1 }
        textView.onMarkedStateChanged = { counter.markedText.append($0) }
        textView.modifierFlagsProvider = { modifiers }
        textView.markedTextProvider = marked
        return textView
    }

    func test_commandReturnSubmitsOnlyOutsideMarkedText() {
        let counter = CallCounter()
        var isMarked = false
        let textView = makeTextView(marked: { isMarked }, counter: counter)
        let selector = #selector(NSResponder.insertNewline(_:))

        textView.doCommand(by: selector)
        XCTAssertEqual(counter.submit, 0, "无 ⌘ 的 Return 不提交")

        textView.modifierFlagsProvider = { .command }
        textView.doCommand(by: selector)
        XCTAssertEqual(counter.submit, 1, "⌘Return 提交")

        // 组合态下按键属于输入法会话：提交必须让位。
        isMarked = true
        textView.doCommand(by: selector)
        XCTAssertEqual(counter.submit, 1, "组合态中 ⌘Return 不得抢输入法")
    }

    func test_plainReturnInsertsNewlineWithoutSubmitting() {
        let counter = CallCounter()
        let textView = makeTextView(modifiers: [], counter: counter)

        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(counter.submit, 0, "普通 Return 只换行，不提交")
        XCTAssertEqual(counter.escape, 0)
    }

    func test_escapeDefersToInputMethodAndPopup() {
        let counter = CallCounter()
        var isMarked = false
        let textView = makeTextView(marked: { isMarked }, counter: counter)
        let selector = #selector(NSResponder.cancelOperation(_:))

        textView.doCommand(by: selector)
        XCTAssertEqual(counter.escape, 1, "未被消费的 Esc 交给窗口隐藏")

        isMarked = true
        textView.doCommand(by: selector)
        XCTAssertEqual(counter.escape, 1, "组合态 Esc 优先关闭候选窗，不关浮窗")
    }

    func test_unhandledCommandsPassThrough() {
        let counter = CallCounter()
        let textView = makeTextView(modifiers: .command, counter: counter)

        textView.doCommand(by: #selector(NSResponder.selectAll(_:)))

        XCTAssertEqual(counter.submit, 0)
        XCTAssertEqual(counter.escape, 0, "其他命令不得触发隐藏")
    }

    func test_markedTextStateIsForwarded() {
        let counter = CallCounter()
        let textView = makeTextView(counter: counter)

        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.unmarkText()

        XCTAssertEqual(counter.markedText.last, false, "组合结束后必须上报 false")
    }
}
