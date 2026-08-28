import AppKit
import SwiftUI

/// 便签窗口内容：工具栏 → 正文编辑区 → 状态栏（SPEC 4.2）。
/// 正文用 NSTextView（点击激活应用 + 系统标准右键菜单），其余为 SwiftUI。
struct StickyNoteContentView: View {
    @ObservedObject var viewModel: StickyNoteViewModel
    let actions: () -> StickyNoteViewActions
    let stringsProvider: () -> Strings

    let onActivateForTyping: () -> Void
    let onToolbarDragEvent: (NSEvent) -> Void
    let onResizeEvent: (NSEvent) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var toolbarWidth: CGFloat = 0
    @State private var showsReminderPanel = false

    private var note: StickyNote { viewModel.note }
    private var palette: StickyNotePalette { StickyNotePalette.palette(for: note.color) }
    private var strings: Strings { stringsProvider() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)
            editor
            statusBar
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background(colorScheme: colorScheme))
        .overlay(alignment: .topTrailing) { reminderPanel }
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .overlay(RoundedRectangle(cornerRadius: StickyNoteChrome.cornerRadius, style: .continuous)
            .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: StickyNoteChrome.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: StickyNoteChrome.cornerRadius, style: .continuous))
    }

    // MARK: - 工具栏

    /// 工具栏整条为拖动区（交互区铺底、控件叠上层），与常见窗口标题栏行为一致；
    /// 按住按钮以外的任意空白处即可拖动整窗。
    private var toolbar: some View {
        ZStack {
            StickyNoteInteractionRegion(onEvent: onToolbarDragEvent)
            HStack(spacing: 6) {
                // 纯装饰握把：暗示工具栏可拖，不拦截事件
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.4))
                    .frame(width: 30, height: 22)
                    .allowsHitTesting(false)
                if toolbarWidth >= StickyNoteChrome.colorDotsCollapseWidth {
                    colorDots
                }
                Spacer(minLength: 4)
                toolbarButton(symbol: "plus", label: strings.stickyNoteNewNote) {
                    actions().onCreateNew()
                }
                pinButton
                toolbarButton(
                    symbol: note.reminderAt != nil ? "bell.fill" : "bell",
                    label: note.reminderAt != nil ? strings.stickyNoteEditReminder : strings.stickyNoteSetReminder
                ) {
                    showsReminderPanel.toggle()
                }
                toolbarButton(symbol: "eye", label: strings.stickyNoteCollapse) {
                    actions().onCollapse(note.id)
                }
                toolbarButton(symbol: "checkmark.circle", label: strings.stickyNoteComplete) {
                    actions().onComplete(note.id)
                }
            }
        }
        .frame(height: 26)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { toolbarWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in toolbarWidth = newValue }
            }
        )
    }

    private var colorDots: some View {
        HStack(spacing: 7) {
            ForEach(StickyNoteColor.allCases, id: \.self) { color in
                let dot = StickyNotePalette.palette(for: color)
                let isSelected = note.color == color
                Circle()
                    .fill(dot.accent)
                    .frame(width: 11, height: 11)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                palette.text(colorScheme: colorScheme).opacity(isSelected ? 0.85 : 0),
                                lineWidth: 1.5
                            )
                            .padding(-2.5)
                    )
                    .contentShape(Circle().inset(by: -4))
                    .onTapGesture { actions().onColorSelected(note.id, color) }
                    .help(colorLabel(for: color))
            }
        }
        .padding(.horizontal, 2)
    }

    private func colorLabel(for color: StickyNoteColor) -> String {
        switch color {
        case .yellow: return strings.stickyNoteColorYellow
        case .mint: return strings.stickyNoteColorMint
        case .blue: return strings.stickyNoteColorBlue
        case .pink: return strings.stickyNoteColorPink
        }
    }

    private func toolbarButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.8))
                .frame(width: StickyNoteChrome.toolbarButtonSize, height: StickyNoteChrome.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    /// 置顶按钮：激活态为橙色圆角方块底 + 白色实心图钉（设计稿 01）。
    private var pinButton: some View {
        Button {
            actions().onTogglePin(note.id)
        } label: {
            Image(systemName: note.pinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    note.pinned ? Color.white : palette.text(colorScheme: colorScheme).opacity(0.8)
                )
                .frame(width: StickyNoteChrome.toolbarButtonSize, height: StickyNoteChrome.toolbarButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(note.pinned ? StickyNoteChrome.pinActiveBackground : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(note.pinned ? strings.stickyNoteUnpin : strings.stickyNotePin)
    }

    // MARK: - 正文

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            StickyNoteTextEditor(
                text: note.content,
                palette: palette,
                colorScheme: colorScheme,
                onActivate: onActivateForTyping,
                onTextChange: { content in
                    viewModel.markSaving()
                    viewModel.updateContentLocally(content)
                    actions().onContentChanged(note.id, content)
                }
            )
            if note.content.isEmpty {
                Text(strings.stickyNotePlaceholder)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isSaving ? Color.secondary.opacity(0.5) : StickyNoteChrome.savedDotColor)
                    .frame(width: 6, height: 6)
                Text(viewModel.isSaving ? strings.stickyNoteSaving : strings.stickyNoteSaved)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.6))
            }
            Spacer(minLength: 8)
            if note.isReminderFired {
                HStack(spacing: 3) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 8))
                    Text(strings.stickyNoteReminderFired)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(palette.accent)
            } else if let reminderAt = note.reminderAt {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8))
                    Text(reminderStatusText(for: reminderAt))
                        .font(.system(size: 10))
                }
                .foregroundStyle(palette.accent)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08))
                .frame(height: 0.5)
        }
    }

    private func reminderStatusText(for date: Date) -> String {
        let formatted = StickyNoteReminderText.displayString(for: date, now: Date(), strings: strings)
        return String(format: strings.stickyNoteReminderAtFormat, formatted)
    }

    // MARK: - 提醒面板

    @ViewBuilder
    private var reminderPanel: some View {
        if showsReminderPanel {
            StickyNoteReminderPanel(
                note: note,
                strings: strings,
                onSetReminder: { date in
                    let result = actions().onSetReminder(note.id, date)
                    if case .failure(.pastTime) = result {
                        return false
                    }
                    return true
                },
                onClearReminder: {
                    actions().onClearReminder(note.id)
                },
                onClose: { showsReminderPanel = false }
            )
            .padding(10)
            .zIndex(10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
    }

    // MARK: - 缩放热区

    private var resizeHandle: some View {
        StickyNoteInteractionRegion(onEvent: onResizeEvent)
            .frame(width: StickyNoteChrome.resizeHandleLength, height: StickyNoteChrome.resizeHandleLength)
            .overlay(
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.5))
                    .allowsHitTesting(false)
            )
            .padding(3)
    }
}

// MARK: - 提醒状态时间文本

enum StickyNoteReminderText {
    /// 「今天 10:48」（同日）或「8月29日 09:00」（跨日，按系统本地化模板）。
    static func displayString(for date: Date, now: Date, strings: Strings) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = .current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return String(format: strings.stickyNoteReminderTodayFormat, formatter.string(from: date))
        }
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter.string(from: date)
    }

    /// 「明早」= 次日 09:00。
    static func tomorrowMorning(from now: Date) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 0) + 1
        components.hour = 9
        components.minute = 0
        return Calendar.current.date(from: components) ?? now.addingTimeInterval(24 * 3600)
    }
}

// MARK: - 拖动 / 缩放交互区（AppKit 事件路径）

/// 透传鼠标事件的透明交互区：controller 依事件类型处理按下 / 拖动 / 松手。
/// 拖动必须走 AppKit 屏幕坐标而非 SwiftUI DragGesture（后者随窗口移动重映射，
/// 会产生反馈抖动）。
@MainActor
final class StickyNoteInteractionRegionView: NSView {
    var onEvent: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onEvent?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onEvent?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onEvent?(event)
    }
}

struct StickyNoteInteractionRegion: NSViewRepresentable {
    let onEvent: (NSEvent) -> Void

    func makeNSView(context: Context) -> StickyNoteInteractionRegionView {
        let view = StickyNoteInteractionRegionView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: StickyNoteInteractionRegionView, context: Context) {
        view.onEvent = onEvent
    }
}

// MARK: - 正文 NSTextView（激活 + 系统右键菜单）

/// 点正文先激活应用（IME），再交给系统处理选择 / 光标。
@MainActor
final class StickyNoteActivatableTextView: NSTextView {
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }
}

struct StickyNoteTextEditor: NSViewRepresentable {
    let text: String
    let palette: StickyNotePalette
    let colorScheme: ColorScheme
    let onActivate: () -> Void
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = StickyNoteActivatableTextView(frame: .zero)
        textView.onActivate = onActivate
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        applyStyle(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.verticalScroller?.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? StickyNoteActivatableTextView else { return }
        textView.onActivate = onActivate
        context.coordinator.onTextChange = onTextChange
        applyStyle(to: textView)
        // 仅外部状态与当前文本不同才回写，避免打断输入
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    private func applyStyle(to textView: NSTextView) {
        let nsText = textNSColor
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = nsText
        textView.insertionPointColor = nsText
    }

    private var textNSColor: NSColor {
        let swiftColor = palette.text(colorScheme: colorScheme)
        return NSColor(swiftColor)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: (String) -> Void

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}

// MARK: - 提醒设置面板

/// 便签内嵌提醒面板：快捷项 + 精确设置 + 清除（SPEC 4.6）。
struct StickyNoteReminderPanel: View {
    let note: StickyNote
    let strings: Strings
    /// 返回 false 表示被拒绝（过去时间），面板保持展开以提示。
    let onSetReminder: (Date) -> Bool
    let onClearReminder: () -> Void
    let onClose: () -> Void

    @State private var draftDate = Date().addingTimeInterval(15 * 60)
    @State private var showsPastTimeError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(strings.stickyNoteSetReminder)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(strings.stickyNoteReminderClose)
            }

            HStack(spacing: 6) {
                quickButton(strings.stickyNoteReminderQuick15) { applyQuick(15 * 60) }
                quickButton(strings.stickyNoteReminderQuick1h) { applyQuick(3600) }
                quickButton(strings.stickyNoteReminderQuickTomorrow) {
                    commit(StickyNoteReminderText.tomorrowMorning(from: Date()))
                }
            }

            DatePicker("", selection: $draftDate)
                .datePickerStyle(.compact)
                .labelsHidden()
                .environment(\.locale, .current)

            if showsPastTimeError {
                Text(strings.stickyNoteReminderPast)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button(strings.stickyNoteReminderSet) {
                    commit(draftDate)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                if note.reminderAt != nil {
                    Button(strings.stickyNoteReminderClear, role: .destructive) {
                        onClearReminder()
                        onClose()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 236, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func applyQuick(_ interval: TimeInterval) {
        commit(Date().addingTimeInterval(interval))
    }

    private func commit(_ date: Date) {
        let accepted = onSetReminder(date)
        if accepted {
            onClose()
        } else {
            showsPastTimeError = true
        }
    }
}
