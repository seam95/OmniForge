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
    private var resizeStartFrame: CGRect?

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
            onWindowDragChanged: { [weak self] translation in
                self?.handleDragChanged(translation)
            },
            onWindowDragEnded: { [weak self] translation in
                self?.handleDragEnded(translation)
            },
            onResizeChanged: { [weak self] translation in
                self?.handleResizeChanged(translation)
            },
            onResizeEnded: { [weak self] translation in
                self?.handleResizeEnded(translation)
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

    private func handleDragChanged(_ translation: CGSize) {
        if dragStartOrigin == nil {
            dragStartOrigin = panel.frame.origin
        }
        guard let start = dragStartOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: start.x + translation.width, y: start.y - translation.height))
    }

    private func handleDragEnded(_ translation: CGSize) {
        defer { dragStartOrigin = nil }
        guard let start = dragStartOrigin else { return }
        let origin = NSPoint(x: start.x + translation.width, y: start.y - translation.height)
        panel.setFrameOrigin(origin)
        onFrameChanged?(noteID, panel.frame)
    }

    private func handleResizeChanged(_ translation: CGSize) {
        let start = resizeStartFrame ?? panel.frame
        if resizeStartFrame == nil {
            resizeStartFrame = panel.frame
        }
        let size = StickyNoteGeometry.clampedSize(
            CGSize(width: start.width + translation.width, height: start.height - translation.height)
        )
        // 右下角热区：锚定左上角，向右下扩展
        panel.setFrame(
            CGRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    private func handleResizeEnded(_ translation: CGSize) {
        handleResizeChanged(translation)
        resizeStartFrame = nil
        onFrameChanged?(noteID, panel.frame)
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
