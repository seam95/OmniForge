import AppKit
import SwiftUI

// MARK: - 浮窗运行时状态

/// 浮窗运行时状态：置顶与聚焦请求。
///
/// 与 `TranslationManager` 的会话状态分开：窗口层级 / 焦点变化不应触发会话对象重算，
/// 而 SwiftUI 视图需要观察这两个量来刷新图标与编辑器焦点。
@MainActor
final class TranslationWindowState: ObservableObject {
    /// 是否置顶（窗口层级 .floating / .normal）。
    @Published var isPinned = false
    /// 聚焦原文请求序号；控制器每次要求聚焦时递增，编辑器只对递增做出响应。
    @Published private(set) var focusInputRequest = 0

    func requestInputFocus() {
        focusInputRequest += 1
    }
}

// MARK: - 窗口控制器

/// 翻译浮窗控制器（SPEC §4）：进程内单窗口、可输入 NSPanel、记忆 frame 并归一化。
///
/// 生命周期约定：
/// - 面板延迟创建，关闭按钮 / Esc 只隐藏不销毁，保留本次会话（manager 状态不受影响）；
/// - 隐藏与关闭都显式调用 `manager.cancel()`，不依赖 SwiftUI `onDisappear`——
///   `orderOut` 不会销毁视图树，SwiftUI 生命周期回调在此不可靠；
/// - `TranslationManager.windowPresenter` 弱引用本控制器，控制器强引用 manager，
///   因此不存在窗口/会话的循环引用；窗口由组合根持有管理器强引用存活。
@MainActor
final class TranslationWindowController: NSObject, NSWindowDelegate, TranslationWindowPresenting {
    /// 可成为 key 的面板：翻译需要键盘输入（含中文输入法会话）。
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    static let defaultSize = NSSize(width: 600, height: 520)
    static let minimumSize = NSSize(width: 440, height: 380)

    private let manager: TranslationManager
    private let preferences: TranslationPreferences
    private let stringsProvider: () -> Strings
    /// 系统翻译会话挂载点（macOS 15+）；并行任务提供，视图侧不直接引用桥接实现。
    private let translationTaskHost: (() -> AnyView)?
    /// 打开设置页（AI 配置 / 权限提示入口）；nil 时浮窗只显示文案。
    private let onOpenSettings: (() -> Void)?

    private let state = TranslationWindowState()
    private var panel: KeyablePanel?
    private var hostingController: NSHostingController<AnyView>?
    /// 面板 frame 的内存记忆：content 重建或窗口收起后 AppKit 可能把 frame 压成异常值。
    private var rememberedFrame: NSRect?
    /// 最近一次渲染到 rootView 的字符串目录，用于语言切换后重建视图。
    private var lastRenderedStrings: Strings?

    /// 动态外观；由 composition root 注入弱引用，attach(panel) 后切换外观即时生效。
    /// 未单独注入时回退 `manager.appearance`（同一实例由 composition root 注入），
    /// 避免外观接线漏掉浮窗时出现浅色窗口套深色内容。
    weak var appearance: AppearanceSettings? {
        didSet {
            if let panel {
                resolvedAppearance?.attach(panel)
            }
        }
    }

    private var resolvedAppearance: AppearanceSettings? {
        appearance ?? manager.appearance
    }

    init(
        manager: TranslationManager,
        preferences: TranslationPreferences,
        stringsProvider: @escaping () -> Strings,
        translationTaskHost: (() -> AnyView)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.manager = manager
        self.preferences = preferences
        self.stringsProvider = stringsProvider
        self.translationTaskHost = translationTaskHost
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    // MARK: - TranslationWindowPresenting

    var isKeyWindow: Bool {
        panel?.isKeyWindow == true
    }

    /// 显示浮窗；`focusInput` 为 true 时把焦点交回原文编辑器。
    ///
    /// 顺序要求（SPEC §3.2）：取词等前置动作必须由调用方在调用前完成；
    /// 本方法只负责把窗口带到当前 Space 并激活 app 以便输入。
    func show(focusInput: Bool) {
        let panel = self.panel ?? makePanel()

        // 语言切换后下一次呼出刷新文案：rootView 只在此时重建，
        // 避免窗口已聚焦时按全局快捷键前置也打断编辑焦点。
        refreshRootViewIfNeeded()

        applyNormalizedFrameIfNeeded(panel)
        applyWindowLevel(panel)

        // 不激活 app 时 makeKey 不生效，窗口只前置不可输入（含输入法）。
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        if focusInput {
            state.requestInputFocus()
        }
    }

    /// 隐藏浮窗：先取消进行中的翻译，再保存 frame 并收起窗口；会话内容保留。
    func hide() {
        // 显式取消，不依赖 SwiftUI disappear：窗口 orderOut 不销毁视图树。
        manager.cancel()
        guard let panel else { return }
        saveWindowFrame(panel)
        panel.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// 关闭按钮行为：隐藏而非销毁，保留本次会话供下次呼出继续查看（SPEC §4）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// 防御式清理：正常路径由 windowShouldClose 拦截；若系统强制关闭窗口，
    /// 仍取消请求并保存 frame，避免迟到响应写回已不可见的界面。
    func windowWillClose(_ notification: Notification) {
        manager.cancel()
        if let panel {
            saveWindowFrame(panel)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        saveWindowFrame(panel)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        saveWindowFrame(panel)
    }

    // MARK: - 置顶

    private func togglePin() {
        state.isPinned.toggle()
        if let panel {
            applyWindowLevel(panel)
        }
    }

    /// 置顶：浮动层级且可跨越 Space；非置顶：普通层级并归属当前 Space。
    /// 层级切换同时重设 collectionBehavior，保证置顶状态不会把窗口永久钉在旧 Space。
    private func applyWindowLevel(_ panel: KeyablePanel) {
        if state.isPinned {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }
    }

    // MARK: - 面板创建

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = stringsProvider().translationTitle
        panel.titleVisibility = .hidden
        // 与剪贴板面板同一配方：内容延伸到标题栏，红绿灯浮在自绘标题行上，
        // 避免系统标题栏与视图内标题重复；顶部 38pt 仍保留系统拖动区域。
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        // 点击其他应用不自动关闭（SPEC §4）：NSPanel 默认会在 app 失活时隐藏。
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.minSize = Self.minimumSize
        panel.delegate = self
        applyWindowLevel(panel)

        // 外观偏好切换即时传导（与剪贴板 / 便签窗口同一白名单机制）。
        resolvedAppearance?.attach(panel)

        let frame = restoredFrame()
        panel.setFrame(frame, display: false)
        rememberedFrame = frame

        let host = NSHostingController(rootView: AnyView(makeRootView()))
        // 窗口尺寸由本控制器记忆与归一化，禁止 hosting controller 按内容固有尺寸
        // 反向改窗口大小（否则缩放后的 frame 会在下一次布局被重置）。
        host.sizingOptions = []
        hostingController = host
        panel.contentViewController = host

        self.panel = panel
        return panel
    }

    private func makeRootView() -> TranslationWindowView {
        let strings = stringsProvider()
        lastRenderedStrings = strings
        return TranslationWindowView(
            manager: manager,
            preferences: preferences,
            windowState: state,
            stringsProvider: stringsProvider,
            translationTaskHost: translationTaskHost,
            onTogglePin: { [weak self] in self?.togglePin() },
            onRequestClose: { [weak self] in self?.hide() },
            onOpenSettings: onOpenSettings
        )
    }

    private func refreshRootViewIfNeeded() {
        guard let hostingController else { return }
        let current = stringsProvider()
        guard current != lastRenderedStrings else { return }
        // 重建 rootView 会重置 SwiftUI 局部状态（编辑器光标位置等），
        // 但正文来自 manager.sourceText，不会丢失；语言切换属于低频操作。
        hostingController.rootView = AnyView(makeRootView())
    }

    // MARK: - frame 记忆与归一化

    /// 恢复 frame：优先持久化值，按最小尺寸钳制后夹回当前可见屏；完全不相交时居中。
    private func restoredFrame() -> NSRect {
        let saved = preferences.loadWindowFrame()
        let size = Self.clampedSize(saved?.size ?? Self.defaultSize)
        let candidate = NSRect(
            origin: saved?.origin ?? centeredOrigin(size: size),
            size: size
        )
        // frame 归一化：系统升级 / 显示器重排后持久化位置可能部分悬出屏外，
        // 夹回可见区而不是仅判断「≥50×50 相交即放行」。
        return WindowFrameVisibility.clampedFrameOnCurrentScreens(candidate) {
            NSRect(origin: self.centeredOrigin(size: size), size: size)
        }
    }

    /// 呼出前校正 frame：尺寸异常时回退记忆 / 持久化值；位置悬出屏幕时夹回可见区。
    private func applyNormalizedFrameIfNeeded(_ panel: KeyablePanel) {
        let current = panel.frame
        guard Self.isValidSize(current.size) else {
            // content 重建 / 窗口收起后 AppKit 可能把 frame 压成异常尺寸：
            // 优先内存记忆，其次持久化值，最后居中。
            let fallback: NSRect
            if let rememberedFrame, Self.isValidSize(rememberedFrame.size) {
                fallback = rememberedFrame
            } else {
                fallback = restoredFrame()
            }
            panel.setFrame(fallback, display: false)
            rememberedFrame = fallback
            return
        }
        let normalized = WindowFrameVisibility.clampedFrameOnCurrentScreens(current) {
            NSRect(origin: self.centeredOrigin(size: current.size), size: current.size)
        }
        guard normalized != current else { return }
        panel.setFrame(normalized, display: false)
        rememberedFrame = normalized
    }

    private func saveWindowFrame(_ panel: NSWindow) {
        let frame = panel.frame
        guard Self.isValidSize(frame.size) else { return }
        rememberedFrame = frame
        preferences.saveWindowFrame(frame)
    }

    private func centeredOrigin(size: NSSize) -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
    }

    private static func clampedSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: max(size.width, minimumSize.width),
            height: max(size.height, minimumSize.height)
        )
    }

    private static func isValidSize(_ size: NSSize) -> Bool {
        size.width >= minimumSize.width && size.height >= minimumSize.height
    }
}
