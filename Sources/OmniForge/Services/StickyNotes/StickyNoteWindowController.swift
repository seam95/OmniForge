import AppKit
import SwiftUI

/// 便签窗口的 SwiftUI 侧动作集合；由 Registry 从 Manager 绑定。
struct StickyNoteViewActions {
    let onContentChanged: (UUID, String) -> Void
    let onColorSelected: (UUID, StickyNoteColor) -> Void
    let onTogglePin: (UUID) -> Void
    let onToggleCollapse: (UUID) -> Void
    let onSetFontSize: (UUID, Double) -> Void
    let onComplete: (UUID) -> Void
    let onCreateNew: () -> Void
    let onSetReminder: (UUID, Date) -> Result<Void, StickyNoteReminderError>
    let onClearReminder: (UUID) -> Void

    static let noop = StickyNoteViewActions(
        onContentChanged: { _, _ in },
        onColorSelected: { _, _ in },
        onTogglePin: { _ in },
        onToggleCollapse: { _ in },
        onSetFontSize: { _, _ in },
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
    /// 最近一次同步的折叠态；用于识别「折叠 / 展开」切换并走收缩动画。
    private var lastCollapsed = false
    /// 折叠切换动画进行中：抑制 windowDidMove / Resize 兜底回写中间态 frame。
    private var isAnimatingFrame = false
    /// 折叠切换的逐步 setFrame 定时器。
    private var frameAnimationTimer: Timer?

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
        self.lastCollapsed = note.collapsed
        super.init()

        panel.delegate = self
        panel.setContentSize(finalFrame.size)
        panel.minSize = Self.minSize(collapsed: note.collapsed)

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
    /// 折叠态目标为折叠条（顶边对齐收缩）；折叠 / 展开切换带收缩动画。
    func apply(note: StickyNote) {
        viewModel.apply(note)
        applyWindowLevel(pinned: note.pinned)
        let isInteracting = dragStartOrigin != nil || resizeStartFrame != nil
        guard !isInteracting else { return }
        let collapsedChanged = note.collapsed != lastCollapsed
        lastCollapsed = note.collapsed
        let target = targetFrame(for: note)
        guard Self.framesDiffer(target, panel.frame) else { return }
        panel.minSize = Self.minSize(collapsed: note.collapsed)
        if collapsedChanged {
            animateFrame(to: target)
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// 折叠 / 展开的窗口收缩动画：定时器逐步 setFrame 逼近目标。
    /// 不用 setFrame(animate:)——窗口服务器按「缩放旧位图」插值，不实时重排内容：
    /// 展开时折叠条内容会被纵向拉伸成拖影、动画结束才跳回真实布局；
    /// 逐步 setFrame 等价程序化拖拽，SwiftUI 每步实时重排，无位图拉伸。
    /// 时长与正文显隐动画（0.18s）对齐；期间 windowDidResize / Move 的
    /// 兜底回写由 isAnimatingFrame 抑制，防止中间态高度落库。
    private func animateFrame(to target: CGRect) {
        frameAnimationTimer?.invalidate()
        isAnimatingFrame = true
        let start = panel.frame
        let t0 = Date()
        let duration: TimeInterval = 0.18
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let progress = min(Date().timeIntervalSince(t0) / duration, 1)
                let eased = Self.easeInOutQuad(progress)
                let frame = CGRect(
                    x: start.minX + (target.minX - start.minX) * eased,
                    y: start.minY + (target.minY - start.minY) * eased,
                    width: start.width + (target.width - start.width) * eased,
                    height: start.height + (target.height - start.height) * eased
                )
                self.panel.setFrame(frame, display: true)
                guard progress >= 1 else { return }
                timer.invalidate()
                self.frameAnimationTimer = nil
                self.isAnimatingFrame = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameAnimationTimer = timer
    }

    /// 二次缓动，近似 SwiftUI easeInOut 曲线。
    private static func easeInOutQuad(_ progress: Double) -> CGFloat {
        let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        return CGFloat(eased)
    }

    /// 目标窗口 frame：展开态 = note.frame（钳制最小尺寸）；折叠态 = 顶边对齐的折叠条。
    private func targetFrame(for note: StickyNote) -> CGRect {
        let clamped = StickyNoteGeometry.clampedSize(note.frame.size)
        let expanded = CGRect(origin: note.frame.origin, size: clamped)
        guard note.collapsed else { return expanded }
        return StickyNoteGeometry.collapsedFrame(expanded: expanded)
    }

    /// 折叠条高度低于常规最小高度，minSize 随折叠态放宽（展开时恢复）。
    private static func minSize(collapsed: Bool) -> CGSize {
        collapsed
            ? CGSize(width: StickyNoteGeometry.minimumSize.width, height: StickyNoteGeometry.collapsedHeight)
            : StickyNoteGeometry.minimumSize
    }

    /// 拖动 / 系统路径 frame 变化的回写值：折叠条换算回展开态
    /// （note.frame 恒存展开尺寸，折叠条位置只贡献 origin）。
    private func reportableFrame() -> CGRect {
        guard lastCollapsed else { return panel.frame }
        return StickyNoteGeometry.expandedFrame(
            fromCollapsed: panel.frame,
            expandedSize: viewModel.note.frame.size
        )
    }

    /// 0.5pt 容差比较，避免亚像素往返导致每次同步都 setFrame。
    private static func framesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    /// 显示窗口：用 orderFrontRegardless——app 未激活时（如在最大化前台 app 中
    /// 触发新建/恢复显示）也要压到前台 app 窗口之上；不激活 app、不抢焦点。
    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    func close() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        isAnimatingFrame = false
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
                onFrameChanged?(noteID, reportableFrame())
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
                onFrameChanged?(noteID, reportableFrame())
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
    /// 折叠切换动画期间与折叠态（折叠条不可缩放）不回写。
    func windowDidMove(_ notification: Notification) {
        guard !isAnimatingFrame, dragStartOrigin == nil else { return }
        onFrameChanged?(noteID, reportableFrame())
    }

    func windowDidResize(_ notification: Notification) {
        guard !isAnimatingFrame, resizeStartFrame == nil, !lastCollapsed else { return }
        onFrameChanged?(noteID, reportableFrame())
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
