import AppKit
import Foundation

/// 无边框透明 NSTextField，按内容自适应尺寸，通过闭包回报 commit/cancel。
///
/// 供文字标注工具在用户输入时使用。完全参照 capcap
/// `EditableTextField`（`EditCanvasView.swift` L3511-3770）：
/// - 顶边锚定固定（`sizeToFitText` 保持 `frame.maxY` 不变，向下生长）。
/// - 拼音组合态（markedText）稳定性：用 `DispatchQueue.main.async` +
///   generation 计数去重，避免在 TextKit 编辑事务内同步重排导致越界。
/// - `control(_:textView:doCommandBy:)`：Esc=cancel、回车=commit、
///   Shift+回车=换行。
/// - `performKeyEquivalent` 手动路由 ⌘A/C/V/X/Z（应用无主菜单）。
/// - `annotationOrigin`：commit 时由当前 frame 反算标注锚点
///   （气泡模式需扣除气泡内边距）。
final class EditableTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?

    /// 描边开关。编辑态只显示纯文字，描边在提交后的 `TextAnnotation` 上渲染。
    var hasStroke: Bool = false
    /// 文字颜色（气泡模式下实际作为气泡/箭头填充色）。
    var annotationColor: NSColor = .red {
        didSet {
            updateAppearanceForCurrentMode()
            onChange?()
        }
    }
    /// 气泡模式开关。
    var hasCallout: Bool = false {
        didSet {
            updateAppearanceForCurrentMode()
            onChange?()
        }
    }
    /// 气泡箭头尾端（可选）。
    var calloutTip: NSPoint? {
        didSet { onChange?() }
    }
    /// 编辑现有文字标注时携带的旋转角度。编辑态浮层保持水平，
    /// 提交后的标注保留原角度而非回到 0。
    var rotation: CGFloat = 0

    /// 提交时反算的标注锚点（画布坐标）。
    /// 普通模式 = frame.origin；气泡模式需扣除气泡内边距。
    var annotationOrigin: NSPoint {
        guard hasCallout else { return frame.origin }
        return NSPoint(
            x: frame.minX + TextAnnotation.calloutHorizontalPadding,
            y: frame.minY + TextAnnotation.calloutVerticalPadding
        )
    }

    private var didFinish = false
    private var wasCanceled = false
    private var textStorageObserver: NSObjectProtocol?
    /// 异步 sizeToFit 的去重代际：每次重新调度自增，旧回调发现代际
    /// 不匹配即放弃，避免组合输入过程中的多次重排相互覆盖。
    private var sizeUpdateGeneration: UInt = 0
    private static let insertNewlineIgnoringFieldEditorSelector = #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
    private static let insertLineBreakSelector = #selector(NSResponder.insertLineBreak(_:))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopObservingFieldEditor()
    }

    private func configure() {
        isBordered = false
        isBezeled = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        delegate = self
        cell?.usesSingleLineMode = false
        cell?.wraps = false
        cell?.isScrollable = false
        maximumNumberOfLines = 0
        target = self
        action = #selector(commitFromAction)
        stringValue = ""
        placeholderString = ""

        // 可见编辑边框，让用户在透明画布上能看到输入框位置。
        wantsLayer = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
    }

    /// 按气泡/普通模式切换外观（文字色、背景色、圆角）。
    private func updateAppearanceForCurrentMode() {
        if hasCallout {
            textColor = TextAnnotation.contrastingTextColor(for: annotationColor)
            layer?.backgroundColor = annotationColor.cgColor
            layer?.cornerRadius = TextAnnotation.calloutCornerRadius
        } else {
            textColor = annotationColor
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
            layer?.cornerRadius = 2
        }
    }

    @objc private func commitFromAction() {
        commit()
    }

    /// 提交当前输入。幂等（`didFinish` 守卫）。
    func commit() {
        guard !didFinish else { return }
        didFinish = true
        let text = liveEditorText
        stopObservingFieldEditor()
        onCommit?(text)
    }

    /// 取消编辑。幂等（`didFinish` 守卫）。
    func cancel() {
        guard !didFinish else { return }
        didFinish = true
        stopObservingFieldEditor()
        onCancel?()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let textView = currentEditor() as? NSTextView else { return }
        observeTextChanges(in: textView)
    }

    /// 监听 NSTextStorage 的 didProcessEditing，在每次编辑（含组合态）
    /// 处理完后调度一次自适应尺寸。参照 capcap L3631-3642。
    private func observeTextChanges(in textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        stopObservingFieldEditor()
        textStorageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: .main
        ) { [weak self, weak textView] _ in
            guard let self, let textView else { return }
            self.scheduleSizeToFitText(using: textView.string)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        sizeToFitText()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        stopObservingFieldEditor()
        guard !didFinish else { return }
        if wasCanceled {
            cancel()
        } else {
            commit()
        }
    }

    /// 命令键路由：Esc=取消、回车=提交、Shift+回车=换行。
    /// 参照 capcap L3658-3679。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            wasCanceled = true
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) {
                insertLineBreak(in: textView)
            } else {
                window?.makeFirstResponder(nil)
            }
            return true
        }
        if commandSelector == Self.insertNewlineIgnoringFieldEditorSelector
            || commandSelector == Self.insertLineBreakSelector {
            insertLineBreak(in: textView)
            return true
        }
        return false
    }

    private func insertLineBreak(in textView: NSTextView) {
        textView.insertText("\n", replacementRange: textView.selectedRange())
        stringValue = textView.string
        sizeToFitText()
    }

    /// 应用无主菜单，标准编辑快捷键（⌘A/C/V/X/Z、⇧⌘Z）无法到达
    /// field editor，这里手动路由。参照 capcap L3690-3718。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if mods == cmd {
            switch chars {
            case "a": currentEditor()?.selectAll(nil); return true
            case "c": currentEditor()?.copy(nil); return true
            case "v": currentEditor()?.paste(nil); return true
            case "x": currentEditor()?.cut(nil); return true
            case "z":
                if let undoMgr = currentEditor()?.undoManager, undoMgr.canUndo {
                    undoMgr.undo(); return true
                }
            default: break
            }
        } else if mods == cmdShift, chars == "z" {
            if let undoMgr = currentEditor()?.undoManager, undoMgr.canRedo {
                undoMgr.redo(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - 自适应尺寸

    /// 按当前文字 + 字体重算宽高，保持顶边锚定，向下生长。
    /// 参照 capcap L3722-3747。
    func sizeToFitText() {
        sizeToFitText(using: liveEditorText)
    }

    /// field editor 中的实时文字（比 stringValue 更新）。
    private var liveEditorText: String {
        (currentEditor() as? NSTextView)?.string ?? stringValue
    }

    private func sizeToFitText(using text: String) {
        guard let font = font else { return }
        let contentSize = TextAnnotation.editorSize(for: text, font: font)
        let size = hasCallout
            ? NSSize(
                width: contentSize.width + TextAnnotation.calloutHorizontalPadding * 2,
                height: contentSize.height + TextAnnotation.calloutVerticalPadding * 2
            )
            : contentSize

        // 顶边锚定：先记下旧顶，改尺寸后把 origin.y 设为「旧顶 - 新高」，
        // 这样字号变化时文字向下生长、字头位置不动。
        let prevTop = frame.maxY
        var f = frame
        f.size = size
        f.origin.y = prevTop - size.height
        guard f != frame else { return }
        frame = f
        onChange?()
    }

    private func stopObservingFieldEditor() {
        sizeUpdateGeneration &+= 1
        guard let textStorageObserver else { return }
        NotificationCenter.default.removeObserver(textStorageObserver)
        self.textStorageObserver = nil
    }

    /// 输入法更新 marked text 发生在 TextKit 编辑事务内，此时同步重排
    /// 尺寸可能让 TextKit 枚举到已失效的 range，故合并到下一个主队列
    /// turn 执行。generation 计数丢弃过期回调。参照 capcap L3760-3769。
    private func scheduleSizeToFitText(using text: String) {
        sizeUpdateGeneration &+= 1
        let generation = sizeUpdateGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.didFinish,
                  generation == self.sizeUpdateGeneration else { return }
            self.sizeToFitText(using: text)
        }
    }
}
