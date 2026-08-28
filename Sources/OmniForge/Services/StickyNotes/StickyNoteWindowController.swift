import AppKit
import SwiftUI

/// 便签窗口的 SwiftUI 侧动作集合；由 Registry 从 Manager 绑定。
struct StickyNoteViewActions {
    let onContentChanged: (UUID, String) -> Void
    let onColorSelected: (UUID, StickyNoteColor) -> Void
    let onTogglePin: (UUID) -> Void
    let onCollapse: (UUID) -> Void
    let onComplete: (UUID) -> Void
    let onCreateNew: () -> Void
    let onSetReminder: (UUID, Date) -> Result<Void, StickyNoteReminderError>
    let onClearReminder: (UUID) -> Void

    static let noop = StickyNoteViewActions(
        onContentChanged: { _, _ in },
        onColorSelected: { _, _ in },
        onTogglePin: { _ in },
        onCollapse: { _ in },
        onComplete: { _ in },
        onCreateNew: {},
        onSetReminder: { _, _ in .failure(.noteNotFound) },
        onClearReminder: { _ in }
    )
}

/// 单便签窗口状态：内容视图观察它；`apply` 是外部状态流入的唯一入口。
@MainActor
final class StickyNoteViewModel: ObservableObject {
    @Published private(set) var note: StickyNote
    /// 输入后到落库同步前的「保存中…」指示。
    @Published private(set) var isSaving = false

    init(note: StickyNote) {
        self.note = note
    }

    func markSaving() {
        isSaving = true
    }

    /// 外部状态同步（Manager 动作 / 落库 flush 后）。
    /// 文本仅在与当前值不同时更新，避免打断正在进行的输入。
    func apply(_ note: StickyNote) {
        self.note = note
        isSaving = false
    }

    func updateContentLocally(_ content: String) {
        note.content = content
    }
}

/// 单便签窗口控制器：KeyablePanel + NSHostingController 内容。
/// 激活策略（SPEC D9）：panel 为 nonactivating，仅点正文时 makeKey + activate（IME），
/// 工具栏按钮不抢当前应用焦点。
@MainActor
final class StickyNoteWindowController: NSObject, NSWindowDelegate {
    let noteID: UUID
    private let panel: StickyNoteKeyablePanel
    private let viewModel: StickyNoteViewModel
    private let actionsProvider: () -> StickyNoteViewActions
    private let stringsProvider: () -> Strings

    /// 窗口 frame 变化（拖动 / 缩放松手）→ Manager 持久化。
    var onFrameChanged: ((UUID, NSRect) -> Void)?
    private var dragStartOrigin: CGPoint?
    private var dragStartScreenLocation: NSPoint?
    private var resizeStartFrame: CGRect?
    private var resizeStartScreenLocation: NSPoint?

    init(
        note: StickyNote,
        actionsProvider: @escaping () -> StickyNoteViewActions,
        stringsProvider: @escaping () -> Strings
    ) {
        self.noteID = note.id
        self.actionsProvider = actionsProvider
        self.stringsProvider = stringsProvider
        let normalized = WindowFrameVisibility.normalizedFrameOnCurrentScreens(note.frame) {
            StickyNoteGeometry.defaultFrame(on: NSScreen.screens.map(\.visibleFrame))
        }
        let clamped = StickyNoteGeometry.clampedSize(normalized.size)
        let finalFrame = CGRect(origin: normalized.origin, size: clamped)
        let panel = StickyNoteKeyablePanel(contentRect: finalFrame)
        self.panel = panel
        self.viewModel = StickyNoteViewModel(note: note)
        super.init()

        panel.delegate = self
        panel.setContentSize(finalFrame.size)
        panel.minSize = StickyNoteGeometry.minimumSize

        let view = StickyNoteContentView(
            viewModel: viewModel,
            actions: actionsProvider,
            stringsProvider: stringsProvider,
            onActivateForTyping: { [weak self] in
                self?.activateForTyping()
            },
            onToolbarDragEvent: { [weak self] event in
                self?.handleToolbarDrag(event)
            },
            onResizeEvent: { [weak self] event in
                self?.handleResize(event)
            }
        )
        let host = NSHostingController(rootView: AnyView(view))
        panel.contentViewController = host
        apply(note: note)
    }

    // MARK: - 状态同步

    /// 全量同步：内容 / 颜色 / 置顶层级 / frame；frame 与窗口一致时不动窗口（幂等）。
    /// 拖动 / 缩放进行中不回写 frame：此时内存坐标尚未经松手回调更新，
    /// 回写会把窗口拽回旧位置（正文防抖落库触发的同步即此场景）。
    func apply(note: StickyNote) {
        viewModel.apply(note)
        applyWindowLevel(pinned: note.pinned)
        let isInteracting = dragStartOrigin != nil || resizeStartFrame != nil
        guard !isInteracting, Self.framesDiffer(note.frame, panel.frame) else { return }
        let clamped = StickyNoteGeometry.clampedSize(note.frame.size)
        panel.setFrame(
            CGRect(origin: note.frame.origin, size: clamped),
            display: true
        )
    }

    /// 0.5pt 容差比较，避免亚像素往返导致每次同步都 setFrame。
    private static func framesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    func show() {
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.delegate = nil
        panel.close()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    // MARK: - 激活（正文点击）

    /// 点正文进入编辑：激活应用并聚焦文本，保证中文输入法可用。
    private func activateForTyping() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeTextViewFirstResponder()
    }

    private func makeTextViewFirstResponder() {
        // makeKey 当拍内 firstResponder 可能尚未就绪，延后一拍设置。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let host = self.panel.contentViewController as? NSHostingController<AnyView> else { return }
            let textView = Self.firstTextView(in: host.view)
            self.panel.makeFirstResponder(textView)
        }
    }

    private static func firstTextView(in view: NSView) -> NSView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - 拖动 / 缩放

    /// 工具栏拖动：以事件屏幕坐标增量移动窗口（对齐贴图窗口先例）。
    /// 不用 SwiftUI DragGesture——窗口一旦移动，其视图坐标系随之重映射，
    /// translation 会跳变并形成反馈抖动；AppKit 事件的屏幕坐标不受窗口移动影响。
    private func handleToolbarDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartOrigin = panel.frame.origin
            dragStartScreenLocation = panel.convertPoint(toScreen: event.locationInWindow)
        case .leftMouseDragged:
            guard let startOrigin = dragStartOrigin,
                  let startLocation = dragStartScreenLocation else { return }
            let current = panel.convertPoint(toScreen: event.locationInWindow)
            panel.setFrameOrigin(
                NSPoint(
                    x: startOrigin.x + (current.x - startLocation.x),
                    y: startOrigin.y + (current.y - startLocation.y)
                )
            )
        case .leftMouseUp:
            if dragStartOrigin != nil {
                dragStartOrigin = nil
                dragStartScreenLocation = nil
                onFrameChanged?(noteID, panel.frame)
            }
        default:
            break
        }
    }

    /// 右下角缩放：锚定窗口左上角，光标位移换算尺寸（同样走事件屏幕坐标）。
    private func handleResize(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            resizeStartFrame = panel.frame
            resizeStartScreenLocation = panel.convertPoint(toScreen: event.locationInWindow)
        case .leftMouseDragged:
            applyResize(from: event)
        case .leftMouseUp:
            if resizeStartFrame != nil {
                applyResize(from: event)
                resizeStartFrame = nil
                resizeStartScreenLocation = nil
                onFrameChanged?(noteID, panel.frame)
            }
        default:
            break
        }
    }

    private func applyResize(from event: NSEvent) {
        guard let startFrame = resizeStartFrame,
              let startLocation = resizeStartScreenLocation else { return }
        let current = panel.convertPoint(toScreen: event.locationInWindow)
        // 屏幕坐标 y 向上为正：向右下拖 = dx 正、dy 负
        let delta = CGSize(
            width: current.x - startLocation.x,
            height: startLocation.y - current.y
        )
        let size = StickyNoteGeometry.clampedSize(
            CGSize(width: startFrame.width + delta.width, height: startFrame.height + delta.height)
        )
        panel.setFrame(
            CGRect(x: startFrame.minX, y: startFrame.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    private func applyWindowLevel(pinned: Bool) {
        if pinned {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        } else {
            // 未置顶：普通层级、归属当前 Space，可被其他窗口遮挡
            panel.level = .normal
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        }
    }

    // MARK: - NSWindowDelegate

    /// 拖动 / 系统路径导致的窗口变化兜底持久化。
    func windowDidMove(_ notification: Notification) {
        if dragStartOrigin == nil {
            onFrameChanged?(noteID, panel.frame)
        }
    }

    func windowDidResize(_ notification: Notification) {
        if resizeStartFrame == nil {
            onFrameChanged?(noteID, panel.frame)
        }
    }
}

/// 可成为 key 的便签面板：borderless + nonactivating（点工具栏不激活应用）+ 有阴影。
@MainActor
final class StickyNoteKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    }
}
