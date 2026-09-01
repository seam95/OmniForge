import AppKit
import SwiftUI

/// 正文 NSTextView 与占位符共用的内边距：两者必须严格同行同列，
/// 光标与「写下就好…」错位即因两处内边距各自为政。
private enum StickyNoteTextInset {
    static let horizontal: CGFloat = 6
    static let top: CGFloat = 8
}

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
    @State private var showsFontPanel = false

    /// `debugShowsFontPanel` 仅供离屏渲染 / 预览直出档位面板打开态。
    init(
        viewModel: StickyNoteViewModel,
        actions: @escaping () -> StickyNoteViewActions,
        stringsProvider: @escaping () -> Strings,
        onActivateForTyping: @escaping () -> Void,
        onToolbarDragEvent: @escaping (NSEvent) -> Void,
        onResizeEvent: @escaping (NSEvent) -> Void,
        debugShowsFontPanel: Bool = false
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.actions = actions
        self.stringsProvider = stringsProvider
        self.onActivateForTyping = onActivateForTyping
        self.onToolbarDragEvent = onToolbarDragEvent
        self.onResizeEvent = onResizeEvent
        _showsFontPanel = State(initialValue: debugShowsFontPanel)
    }

    private var note: StickyNote { viewModel.note }
    private var palette: StickyNotePalette { StickyNotePalette.palette(for: note.color) }
    private var strings: Strings { stringsProvider() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)
            if !note.collapsed {
                editor
                statusBar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        // 顶对齐：折叠后正文移除、VStack 只剩工具栏，默认居中会让按钮
        // 在窗口收缩动画期间先下沉再回弹；钉顶边与窗口层顶边对齐收缩一致。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.background(colorScheme: colorScheme))
        .overlay(alignment: .topTrailing) { reminderPanel }
        .overlay(alignment: .top) { fontPanel }
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .overlay(RoundedRectangle(cornerRadius: StickyNoteChrome.cornerRadius, style: .continuous)
            .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: StickyNoteChrome.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: StickyNoteChrome.cornerRadius, style: .continuous))
        .omniNoFocusRing()
        // 正文显隐与窗口收缩动画（AppKit setFrame animate）时长衔接。
        .animation(.easeInOut(duration: 0.18), value: note.collapsed)
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
                    showsFontPanel = false
                    showsReminderPanel.toggle()
                }
                fontSizeToolbarButton
                toolbarButton(
                    symbol: note.collapsed ? "chevron.down" : "chevron.up",
                    label: note.collapsed ? strings.stickyNoteExpand : strings.stickyNoteCollapse
                ) {
                    actions().onToggleCollapse(note.id)
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

    /// 字号按钮：文字「Aa」而非 SF Symbol——textformat.size 在中文系统
    /// 会渲染成汉字「大小」，与线框 symbol 族风格冲突（对齐 pinButton 专用视图先例）。
    private var fontSizeToolbarButton: some View {
        Button {
            showsReminderPanel = false
            showsFontPanel.toggle()
        } label: {
            Text("Aa")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.8))
                .frame(width: StickyNoteChrome.toolbarButtonSize, height: StickyNoteChrome.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strings.stickyNoteFontSize)
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
                fontSize: note.fontSize,
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
                    .font(.system(size: note.fontSize))
                    .foregroundStyle(palette.text(colorScheme: colorScheme).opacity(0.45))
                    .padding(.horizontal, StickyNoteTextInset.horizontal)
                    .padding(.top, StickyNoteTextInset.top)
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

    // MARK: - 字号档位面板

    /// 横向档位条：数字以档位字号直接渲染（即所见预览），当前档 accent 高亮，
    /// 点选即关。水平居中 + 顶部留白 34 落在工具栏下方（下拉式展开）：
    /// 面板宽恒小于最小窗宽 240，任何便签宽度下完整可点，Aa 按钮保持可见可再点关闭。
    @ViewBuilder
    private var fontPanel: some View {
        if showsFontPanel {
            HStack(spacing: 4) {
                ForEach(StickyNote.fontSizeSteps, id: \.self) { size in
                    let isCurrent = note.fontSize == size
                    Button {
                        actions().onSetFontSize(note.id, size)
                        showsFontPanel = false
                    } label: {
                        Text("\(Int(size))")
                            .font(.system(size: size, weight: isCurrent ? .semibold : .regular))
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(isCurrent ? palette.accent : palette.text(colorScheme: colorScheme).opacity(0.75))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isCurrent ? palette.accent.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.top, 34)
            .zIndex(10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    // MARK: - 缩放热区

    /// 折叠条不可缩放：仅展开态显示。
    @ViewBuilder
    private var resizeHandle: some View {
        if !note.collapsed {
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
    let fontSize: CGFloat
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
        // 显式内边距并去掉默认 5pt 行片段内衬，使文字原点与占位符共用
        // StickyNoteTextInset（否则光标与占位符上下错一行）
        textView.textContainerInset = NSSize(
            width: StickyNoteTextInset.horizontal,
            height: StickyNoteTextInset.top
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        applyStyle(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        StickyNoteScroller.install(on: scrollView).knobColor = scrollerKnobColor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? StickyNoteActivatableTextView else { return }
        textView.onActivate = onActivate
        context.coordinator.onTextChange = onTextChange
        applyStyle(to: textView)
        (scrollView.verticalScroller as? StickyNoteScroller)?.knobColor = scrollerKnobColor
        // 仅外部状态与当前文本不同才回写，避免打断输入
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    private func applyStyle(to textView: NSTextView) {
        let nsText = textNSColor
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = nsText
        textView.insertionPointColor = nsText
    }

    private var textNSColor: NSColor {
        let swiftColor = palette.text(colorScheme: colorScheme)
        return NSColor(swiftColor)
    }

    /// 滚动条 knob 取便签文字色的低透明度版本，与纸质底色协调。
    private var scrollerKnobColor: NSColor {
        textNSColor.withAlphaComponent(0.32)
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

/// 便签内嵌提醒面板：标题栏 + 蓝色胶囊快捷项 + 精确时间 + 设置/清除（设计稿 02）。
struct StickyNoteReminderPanel: View {
    let note: StickyNote
    let strings: Strings
    /// 返回 false 表示被拒绝（过去时间），面板保持展开以提示。
    let onSetReminder: (Date) -> Bool
    let onClearReminder: () -> Void
    let onClose: () -> Void

    @State private var draftDate = Date().addingTimeInterval(15 * 60)
    @State private var showsPastTimeError = false

    /// 清除按钮红色（与管理页删除色一致）。
    private let destructiveRed = Color(red: 0.95, green: 0.35, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentColor)
                Text(strings.stickyNoteSetReminder)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(strings.stickyNoteReminderClose)
            }

            HStack(spacing: 6) {
                quickCapsule(strings.stickyNoteReminderQuick15) { applyQuick(15 * 60) }
                quickCapsule(strings.stickyNoteReminderQuick1h) { applyQuick(3600) }
                quickCapsule(strings.stickyNoteReminderQuickTomorrow) {
                    commit(StickyNoteReminderText.tomorrowMorning(from: Date()))
                }
            }

            Text(strings.stickyNoteReminderExactTime)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

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
                Button {
                    commit(draftDate)
                } label: {
                    Text(strings.stickyNoteReminderSet)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                if note.reminderAt != nil {
                    Button {
                        onClearReminder()
                        onClose()
                    } label: {
                        Text(strings.stickyNoteReminderClear)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(destructiveRed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(destructiveRed.opacity(0.07))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(destructiveRed.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 244, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    /// 快捷项胶囊：蓝字 + 浅蓝底 + 细描边。
    private func quickCapsule(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.accentColor.opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
