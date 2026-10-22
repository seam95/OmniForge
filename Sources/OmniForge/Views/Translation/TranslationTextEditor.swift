import AppKit
import SwiftUI

// MARK: - 原文编辑区

/// 原文编辑区：包装 NSTextView，提供多行编辑、撤销与系统右键菜单。
///
/// 按键约定（SPEC §4）：
/// - 普通 Return：交回系统 `insertNewline:`，插入换行；
/// - ⌘Return：提交翻译，仅在无输入法组合态时触发；
/// - Esc：输入法组合态与系统弹层（候选窗、自动补全）优先处理；只有真正落到
///   `cancelOperation:` 时才回调窗口隐藏，避免把「关闭候选窗」误判成关窗。
struct TranslationTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// 递增的聚焦请求序号：controller 每次呼出且需要聚焦原文时递增。
    let focusRequest: Int
    let onSubmit: () -> Void
    let onEscape: () -> Void
    /// 输入法组合态变化：外层据此隐藏占位符，避免拼音与占位文字重叠。
    let onMarkedTextChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TranslationInputTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onMarkedStateChanged = onMarkedTextChange

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TranslationInputTextView else { return }
        textView.onSubmit = onSubmit
        textView.onEscape = onEscape
        textView.onMarkedStateChanged = onMarkedTextChange

        // 外部文本回写：组合态期间绝不回写——此时 textView.string 含未确认拼音，
        // 回写等于清空组合文字并打断输入法会话；差异在组合结束后的下一拍补齐。
        if !textView.hasMarkedText(), textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        // 聚焦请求只在序号递增时执行：首次挂载不抢焦点（打开历史时不需要编辑原文），
        // 视觉首帧后再 makeFirstResponder，避免窗口尚未成为 key window 时设置失效。
        guard context.coordinator.lastAppliedFocusRequest != focusRequest else { return }
        context.coordinator.lastAppliedFocusRequest = focusRequest
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationTextEditor
        /// 已执行的聚焦请求序号；初始等于当前值，保证首次挂载不自动聚焦。
        var lastAppliedFocusRequest: Int

        init(parent: TranslationTextEditor) {
            self.parent = parent
            self.lastAppliedFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - NSTextView 子类

/// 自定义 NSTextView：把「⌘Return 提交 / Esc 隐藏 / 组合态上报」收口在按键命令层。
///
/// 不覆盖 keyDown 而使用 `doCommandBy`：系统先把按键解释成命令，输入法与系统弹层
/// 有机会先行消费（组合态 / 候选窗 / 自动补全），只有未被消费的命令才走到这里。
@MainActor
final class TranslationInputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onMarkedStateChanged: ((Bool) -> Void)?

    // 测试钩子：生产为 nil，分别回落到当前事件修饰符与 hasMarkedText()。
    // 自动化测试无法稳定构造真实输入法会话与 keyDown 事件，故留这两个注入点。
    var modifierFlagsProvider: (() -> NSEvent.ModifierFlags)?
    var markedTextProvider: (() -> Bool)?

    /// AppKit 的文本命令入口：`NSResponder.doCommand(by:)` 由输入法上下文在
    /// 解释按键后调用；覆盖它并在需要时**不调用 super** 即可拦截命令执行。
    /// 返回值型拦截不可用，因此「未处理」的路径显式交回 super。
    override func doCommand(by selector: Selector) {
        // 组合态（marked text）下按键属于输入法会话，全部交回系统。
        if markedTextProvider?() ?? hasMarkedText() {
            super.doCommand(by: selector)
            return
        }

        let modifierFlags = modifierFlagsProvider?() ?? NSApp.currentEvent?.modifierFlags ?? []
        if selector == #selector(NSResponder.insertNewline(_:)),
           modifierFlags.contains(.command) {
            onSubmit?()
            return
        }

        // 只有确实未被输入法 / 系统弹层消费的 Esc 才落到 cancelOperation。
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return
        }

        super.doCommand(by: selector)
    }

    // 组合态进入 / 更新（setMarkedText）、结束（unmarkText / insertText 确认上屏）
    // 都上报一次；组合态期间 textDidChange 不回调，SwiftUI 侧无从自行感知。
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedStateChanged?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedStateChanged?(hasMarkedText())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onMarkedStateChanged?(hasMarkedText())
    }
}
