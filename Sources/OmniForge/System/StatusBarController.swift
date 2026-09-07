import AppKit
import Combine
import SwiftUI

// MARK: - 状态栏指标协议与协调器

protocol StatusItemSink: AnyObject {
    var mainItemIsVisible: Bool { get set }
    var metricItems: [NSStatusItem] { get set }
}

final class StatusBarMetricCoordinator {
    private weak var sink: StatusItemSink?
    /// 测试可注入；生产默认走系统状态栏。
    private let makeItem: () -> NSStatusItem
    private let removeItem: (NSStatusItem) -> Void

    init(
        sink: StatusItemSink,
        makeItem: @escaping () -> NSStatusItem = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        },
        removeItem: @escaping (NSStatusItem) -> Void = { item in
            NSStatusBar.system.removeStatusItem(item)
        }
    ) {
        self.sink = sink
        self.makeItem = makeItem
        self.removeItem = removeItem
    }

    /// - separate=false（合并）：只保留主 status item，title 放所有 metric block attachment
    /// - separate=true（独立）：每个 metric 一个 status item
    func apply(
        mergedTitle: NSAttributedString,
        separateGroups: [NSAttributedString],
        separate: Bool,
        hideMainIcon: Bool = false,
        mainIcon: NSImage? = nil
    ) {
        guard let sink else { return }
        let mainStatusItem = (sink as? StatusBarMetricSink)?.statusItem
        let mainButton = mainStatusItem?.button
        let hasMetrics = separate
            ? !separateGroups.isEmpty
            : mergedTitle.length > 0

        if !hasMetrics {
            clearMetricItems(on: sink)
            if let mainButton {
                mainButton.attributedTitle = NSAttributedString(string: "")
                mainButton.image = mainIcon
                mainButton.imagePosition = .imageOnly
            }
            sink.mainItemIsVisible = true
            mainStatusItem?.isVisible = true
            return
        }

        if separate {
            // 按目标数量增减，复用已有 NSStatusItem，避免每 tick 抖动
            let wanted = separateGroups.count
            while sink.metricItems.count > wanted {
                if let last = sink.metricItems.popLast() {
                    removeItem(last)
                }
            }
            while sink.metricItems.count < wanted {
                let item = makeItem()
                item.button?.imagePosition = .noImage
                sink.metricItems.append(item)
            }
            for (index, group) in separateGroups.enumerated() {
                let button = sink.metricItems[index].button
                button?.image = nil
                button?.imagePosition = .noImage
                button?.attributedTitle = group
                button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                // 与主按钮一致：裁剪而非换行，attachment 双行块可完整显示
                button?.cell?.lineBreakMode = .byClipping
                button?.cell?.usesSingleLineMode = false
            }

            // 独立模式下主图标可隐藏；否则只显示主图标
            if let mainButton {
                mainButton.attributedTitle = NSAttributedString(string: "")
                mainButton.image = mainIcon
                mainButton.imagePosition = .imageOnly
            }
            sink.mainItemIsVisible = !hideMainIcon
            mainStatusItem?.isVisible = !hideMainIcon
        } else {
            // 合并模式：必须移除所有独立项，只留主 item
            clearMetricItems(on: sink)
            if let mainButton {
                // 合并模式：主图标 + attributedTitle（metrics attachment）
                mainButton.image = hideMainIcon ? nil : mainIcon
                // imageLeading 自带图标与标题间距，不再追加空格字符
                mainButton.attributedTitle = mergedTitle
                mainButton.imagePosition = hideMainIcon ? .noImage : .imageLeading
                mainButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                mainButton.alignment = .left
                mainButton.cell?.lineBreakMode = .byClipping
                mainButton.cell?.usesSingleLineMode = false
            }
            sink.mainItemIsVisible = true
            mainStatusItem?.isVisible = true
            mainStatusItem?.length = NSStatusItem.variableLength
        }
    }

    private func clearMetricItems(on sink: StatusItemSink) {
        for item in sink.metricItems {
            removeItem(item)
        }
        sink.metricItems = []
    }
}

private final class StatusBarMetricSink: StatusItemSink {
    let statusItem: NSStatusItem
    var mainItemIsVisible = true
    var metricItems: [NSStatusItem] = []

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }
}

// MARK: - 状态栏控制器

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    /// 控制中心自管面板窗口（替代 NSPopover：无锚定跟随，位置钉死）。
    private let panel: ControlCenterPanelWindow
    private let state: AppState
    private let clipboardWindowController: ClipboardWindowController
    /// 打开设置；tab=nil 表示默认页，`.keepAwake` 由右键菜单使用。
    private let onOpenSettings: (SettingsToolbarTab?) -> Void
    private var cancellable: AnyCancellable?
    private var blueDotView: LockBadgeDotView?
    var lockBadgeView: NSView? { blueDotView }
    private var metricCoordinator: StatusBarMetricCoordinator?
    /// 必须强引用：coordinator 内部只 weak 持有 sink，局部创建会立刻释放，导致 apply 空跑。
    private var metricSink: StatusBarMetricSink?
    private var monitorCancellables = Set<AnyCancellable>()
    private var featureCancellables = Set<AnyCancellable>()
    /// 有指标且开启「隐藏主图标」时为 true；用于抑制锁定蓝点。
    private var isMainIconHiddenByMetrics = false
    /// 最近一次 metrics 合并 title；与 countdown 单路径合成。
    private var lastMetricsMergedTitle = NSAttributedString(string: "")
    private var lastMetricsSeparateGroups: [NSAttributedString] = []
    private var lastMetricsSeparate = false
    private var lastKeepAwakeRender: StatusBarRenderState?
    private var keepAwakeCancellables = Set<AnyCancellable>()
    private var keepAwakeRefreshTimer: AnyCancellable?
    /// Escape 关闭监听（面板可见期间挂载，NSPopover transient 的自管等价物）。
    private var escapeKeyMonitor: Any?
    /// 失焦关闭时间戳：按钮点击的 mouseDown 先触发 resignKey 关闭面板，
    /// mouseUp 的 action 若紧随其后应视为「关闭意图」而非「重开」。
    private var panelDismissedByFocusLossAt: Date?

    static func menuBarIcon() -> NSImage? {
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            return image
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold, scale: .medium)
        let fallback = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        fallback?.isTemplate = true
        fallback?.size = NSSize(width: 15, height: 15)
        return fallback
    }

    init(
        state: AppState,
        clipboardWindowController: ClipboardWindowController,
        onOpenSettings: @escaping (SettingsToolbarTab?) -> Void = { _ in }
    ) {
        self.state = state
        self.clipboardWindowController = clipboardWindowController
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let panel = ControlCenterPanelWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ControlCenterContentMetrics.panelWidth,
                height: 200
            )
        )
        self.panel = panel

        super.init()
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.closePanel() }

        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageOnly
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.alignment = .left
            button.cell?.lineBreakMode = .byClipping
            button.cell?.usesSingleLineMode = false
            button.action = #selector(togglePopover)
            button.target = self
            setupBlueDot(in: button)
        }

        // 清洁模式启动即收起控制中心面板：面板浮在遮罩上碍事（SPEC D14）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCleaningModeDidStart),
            name: CleaningModeManager.didStartNotification,
            object: nil
        )

        rebindFeatureObservers()
        FeatureRuntime.shared.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebindFeatureObservers()
            }
            .store(in: &featureCancellables)
    }

    deinit {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
    }

    @objc private func handleCleaningModeDidStart() {
        if panel.isVisible {
            closePanel()
        }
    }

    private func rebindFeatureObservers() {
        cancellable = nil
        monitorCancellables.removeAll()

        if let lockState = state.lockState {
            cancellable = lockState.$isLocked
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLocked in
                    guard let self else { return }
                    self.updateLockBadgeVisibility(isLocked: isLocked)
                }
            updateLockBadgeVisibility(isLocked: lockState.isLocked)
        } else {
            blueDotView?.isHidden = true
        }

        setupMonitorMetrics()
        setupKeepAwakeStatusBar()
    }

    private func setupKeepAwakeStatusBar() {
        keepAwakeCancellables.removeAll()
        keepAwakeRefreshTimer?.cancel()
        keepAwakeRefreshTimer = nil

        refreshKeepAwakeRender()

        if let manager = state.keepAwakeManager {
            manager.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refreshKeepAwakeRender()
                }
                .store(in: &keepAwakeCancellables)
        }

        // showCountdown 等仅写 UserDefaults，不经过 manager 发布；监听 defaults 立即刷新。
        // refreshKeepAwakeRender 有 render 相等短路，高频 didChange 成本可接受。
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshKeepAwakeRender()
            }
            .store(in: &keepAwakeCancellables)

        // 菜单栏倒计时每 30 秒刷新一次。
        keepAwakeRefreshTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshKeepAwakeRender()
            }
    }

    /// keep-awake「已安装且 Manager 已注入」判定；与控制中心 popover 面板保持同一标准。
    /// 仅 availability=true 但 Manager 缺失（启动期未 rebind）时为 false，避免状态栏与面板互相矛盾。
    private var keepAwakeActivated: Bool {
        FeatureRuntime.shared.isAvailable(.keepAwake)
            && state.keepAwakeManager != nil
    }

    /// 单一 keep-awake 相关写入：固定活动着色 / 倒计时后缀 / tooltip / 右键菜单。
    private func refreshKeepAwakeRender() {
        var showCountdown = false
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.keepAwakeShowCountdown) != nil {
            showCountdown = UserDefaults.standard.bool(forKey: UserDefaultsKeys.keepAwakeShowCountdown)
        }

        let manager = state.keepAwakeManager
        let input = StatusBarRenderInput(
            isFeatureAvailable: keepAwakeActivated,
            sessionState: manager?.state ?? .inactive,
            lastOperationError: manager?.lastOperationError,
            showCountdown: showCountdown,
            isInputLocked: state.lockState?.isLocked == true,
            hideMainIconWhenMetricsVisible: isMainIconHiddenByMetrics,
            hasVisibleMetrics: isMainIconHiddenByMetrics,
            metricsSeparateItems: false,
            now: Date()
        )
        let next = StatusBarRenderStateBuilder.build(input)
        guard next != lastKeepAwakeRender else { return }
        lastKeepAwakeRender = next
        applyKeepAwakeRender(next)
    }

    private func applyKeepAwakeRender(_ render: StatusBarRenderState) {
        guard let button = statusItem.button else { return }

        // 图标着色（仅图标；cleanup 红色覆盖用户 tint）
        let baseImage = Self.menuBarIcon()
        switch render.iconColor {
        case .template:
            button.image = baseImage
            button.contentTintColor = nil
        case .tint(let tint):
            button.image = baseImage
            button.contentTintColor = nsColor(for: tint)
        case .cleanupWarning:
            button.image = baseImage
            button.contentTintColor = .systemRed
        }

        // 倒计时与 metrics 统一由 composeMainTitle 写入；此处只刷新 icon/tooltip/menu。
        applyComposedMainTitle(keepAwakeRender: render)

        // 活动会话必须保持主 item 可见，覆盖 metrics hide-main。
        if render.mainItemVisible {
            statusItem.isVisible = true
        }

        button.toolTip = tooltipString(for: render.tooltip)
        let shouldHideBadge = !render.showLockBadge || isMainIconHiddenByMetrics
        blueDotView?.isHidden = shouldHideBadge
        if !shouldHideBadge {
            layoutLockBadge()
        }

        installRightClickMenu(render)
    }

    /// 单一 title 写入：countdown 前缀 + metrics attributedTitle。
    private func applyComposedMainTitle(keepAwakeRender: StatusBarRenderState?) {
        guard let button = statusItem.button else { return }
        let countdown = keepAwakeRender?.countdown.displayString ?? ""
        let composed = Self.composeMainTitle(
            countdown: countdown,
            metricsTitle: lastMetricsMergedTitle
        )
        if composed.length == 0 {
            // 无 countdown 且无 metrics：保留 metric coordinator 已写内容的清理路径。
            if lastMetricsMergedTitle.length == 0, !lastMetricsSeparate {
                // 仅当无 metrics 时清理倒计时残留。
                if button.attributedTitle.string.contains("min")
                    || button.attributedTitle.string.contains("∞")
                    || button.title.contains("min")
                    || button.title.contains("∞") {
                    button.title = ""
                    button.attributedTitle = NSAttributedString(string: "")
                    button.imagePosition = .imageOnly
                    layoutLockBadge()
                }
            }
            return
        }
        button.attributedTitle = composed
        button.imagePosition = .imageLeading
        layoutLockBadge()
    }

    /// countdown 纯文本前缀 + metrics attributed（attachments 保留）。
    static func composeMainTitle(
        countdown: String,
        metricsTitle: NSAttributedString
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let trimmedCountdown = countdown.trimmingCharacters(in: .whitespaces)
        if !trimmedCountdown.isEmpty {
            result.append(NSAttributedString(string: " \(trimmedCountdown)"))
        }
        if metricsTitle.length > 0 {
            if result.length > 0 {
                result.append(NSAttributedString(string: " "))
            } else {
                result.append(NSAttributedString(string: " "))
            }
            result.append(metricsTitle)
        }
        return result
    }

    private func installRightClickMenu(_ render: StatusBarRenderState) {
        // 使用 button 的其他鼠标事件构建右键菜单，避免覆盖左键 popover。
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        // 存储最新 render 供 click handler 使用
        latestContextMenuRender = render
    }

    private var latestContextMenuRender: StatusBarRenderState?

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if let render = latestContextMenuRender,
               let button = statusItem.button,
               let menu = makeContextMenu(from: render) {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
            return
        }
        togglePopover()
    }

    private func makeContextMenu(from render: StatusBarRenderState) -> NSMenu? {
        let hasKeepAwake = FeatureRuntime.shared.isAvailable(.keepAwake)
        let pinRegistry = FeatureRuntime.shared
            .manager(for: .screenshot, as: ScreenshotFeatureManager.self)?
            .pinnedScreenshotRegistry
        let hasPinsMenu = pinRegistry != nil
        let hasStickyNotes = FeatureRuntime.shared.isAvailable(.stickyNotes)
        guard hasKeepAwake || hasPinsMenu || hasStickyNotes || render.includeQuit else {
            return nil
        }

        let menu = NSMenu()
        let s = state.l10n.s

        // 决策 8.4-13：钉图托盘入口（右键主路径，与 keep-awake 同菜单，单一数据源）。
        if let pinRegistry {
            let handles = pinRegistry.allPinned()
            let pinsMenu = PinnedScreenshotMenuBuilder.buildMenu(
                handles: handles,
                strings: s,
                target: self,
                copySelector: #selector(pinnedCopy(_:)),
                saveSelector: #selector(pinnedSave(_:)),
                toggleClickThroughSelector: #selector(pinnedToggleClickThrough(_:)),
                toggleLockSelector: #selector(pinnedToggleLock(_:)),
                closeSelector: #selector(pinnedClose(_:)),
                closeAllSelector: #selector(pinnedCloseAll)
            )
            let pinsRoot = NSMenuItem(title: s.pinnedMenuTitle, action: nil, keyEquivalent: "")
            pinsRoot.submenu = pinsMenu
            menu.addItem(pinsRoot)
            if hasKeepAwake || hasStickyNotes {
                menu.addItem(.separator())
            }
        }

        // 桌面便签托盘区（SPEC 4.8：仅功能可用时显示，结构对齐防休眠区）。
        if hasStickyNotes {
            menu.addItem(withTitle: s.stickyNoteMenuNew, action: #selector(stickyNoteNew), keyEquivalent: "")
            menu.addItem(withTitle: s.stickyNoteMenuShowAll, action: #selector(stickyNoteShowAll), keyEquivalent: "")
            menu.addItem(withTitle: s.stickyNoteMenuHideAll, action: #selector(stickyNoteHideAll), keyEquivalent: "")
            for item in menu.items where item.action != nil {
                item.target = self
            }
            if hasKeepAwake {
                menu.addItem(.separator())
            }
        }

        if hasKeepAwake {
            switch render.contextMenu {
            case .inactive(let canRetry):
                if canRetry {
                    menu.addItem(withTitle: s.keepAwakeMenuRetryLastStart, action: #selector(keepAwakeStartDefault), keyEquivalent: "")
                } else {
                    menu.addItem(withTitle: s.keepAwakeMenuStartDefault, action: #selector(keepAwakeStartDefault), keyEquivalent: "")
                }
                let durations = NSMenu(title: s.keepAwakeMenuStartDuration)
                // 0 = 不限时（无限期）；与 KeepAwakeDuration 合法值对齐
                for minutes in [15, 30, 60, 120, 240, 480, 0] {
                    let label: String
                    switch minutes {
                    case 0: label = s.keepAwakeDurationIndefinite
                    case 60: label = String(format: s.keepAwakeDurationHoursFormat, 1)
                    case 120: label = String(format: s.keepAwakeDurationHoursFormat, 2)
                    case 240: label = String(format: s.keepAwakeDurationHoursFormat, 4)
                    case 480: label = String(format: s.keepAwakeDurationHoursFormat, 8)
                    default: label = String(format: s.keepAwakeDurationMinutesFormat, minutes)
                    }
                    let item = NSMenuItem(title: label, action: #selector(keepAwakeStartDuration(_:)), keyEquivalent: "")
                    item.tag = minutes
                    item.target = self
                    durations.addItem(item)
                }
                let parent = NSMenuItem(title: s.keepAwakeMenuStartDuration, action: nil, keyEquivalent: "")
                parent.submenu = durations
                menu.addItem(parent)
            case .transitional:
                let item = NSMenuItem(title: s.keepAwakeMenuProcessing, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .active:
                menu.addItem(withTitle: s.keepAwakeMenuStop, action: #selector(keepAwakeStop), keyEquivalent: "")
            case .cleanupRequired:
                menu.addItem(withTitle: s.keepAwakeMenuRetryCleanup, action: #selector(keepAwakeRetryCleanup), keyEquivalent: "")
            }

            for item in menu.items where item.action != nil {
                item.target = self
            }

            if render.includeOpenKeepAwakeSettings {
                menu.addItem(NSMenuItem.separator())
                let settings = NSMenuItem(
                    title: s.keepAwakeMenuOpenSettings,
                    action: #selector(openKeepAwakeSettings),
                    keyEquivalent: ""
                )
                settings.target = self
                menu.addItem(settings)
            }
        }

        if render.includeQuit {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let quit = NSMenuItem(title: s.keepAwakeMenuQuit, action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }
        return menu
    }

    // MARK: - 钉图托盘动作（决策 8.4-13）

    private func pinnedRegistry() -> PinnedScreenshotRegistry? {
        FeatureRuntime.shared
            .manager(for: .screenshot, as: ScreenshotFeatureManager.self)?
            .pinnedScreenshotRegistry
    }

    private func pinnedID(from sender: Any?) -> UUID? {
        (sender as? NSMenuItem)
            .flatMap { $0.representedObject as? PinnedScreenshotMenuBuilder.PinActionRef }?
            .id
    }

    private func performPinnedAction(_ body: (PinnedScreenshotRegistry, UUID) throws -> Void, sender: Any?) {
        guard let registry = pinnedRegistry(), let id = pinnedID(from: sender) else { return }
        do {
            try body(registry, id)
        } catch {
            // 失败可见：写到 feature manager lastError，不静默吞
            let message = String(
                format: state.l10n.s.pinnedMenuActionFailedFormat,
                String(describing: error)
            )
            FeatureRuntime.shared
                .manager(for: .screenshot, as: ScreenshotFeatureManager.self)?
                .recordMenuError(message)
        }
    }

    @objc private func pinnedCopy(_ sender: Any?) {
        performPinnedAction({ try $0.copy($1) }, sender: sender)
    }

    @objc private func pinnedSave(_ sender: Any?) {
        performPinnedAction({ try $0.save($1) }, sender: sender)
    }

    @objc private func pinnedToggleClickThrough(_ sender: Any?) {
        performPinnedAction({ registry, id in
            guard let handle = registry.handle(for: id) else {
                throw PinnedScreenshotError.notFound(id)
            }
            try registry.setClickThrough(id, !handle.isClickThrough)
        }, sender: sender)
    }

    @objc private func pinnedToggleLock(_ sender: Any?) {
        performPinnedAction({ registry, id in
            guard let handle = registry.handle(for: id) else {
                throw PinnedScreenshotError.notFound(id)
            }
            try registry.setLocked(id, !handle.isLocked)
        }, sender: sender)
    }

    @objc private func pinnedClose(_ sender: Any?) {
        performPinnedAction({ try $0.close($1) }, sender: sender)
    }

    @objc private func pinnedCloseAll() {
        pinnedRegistry()?.closeAll()
    }

    // MARK: - 桌面便签托盘动作

    private func stickyNoteManager() -> StickyNoteManager? {
        FeatureRuntime.shared.manager(for: .stickyNotes, as: StickyNoteManager.self)
    }

    @objc private func stickyNoteNew() {
        stickyNoteManager()?.create()
    }

    @objc private func stickyNoteShowAll() {
        stickyNoteManager()?.showAll()
    }

    @objc private func stickyNoteHideAll() {
        stickyNoteManager()?.hideAll()
    }

    @objc private func keepAwakeStartDefault() {
        state.keepAwakeManager?.start()
    }

    @objc private func keepAwakeStartDuration(_ sender: NSMenuItem) {
        let minutes = sender.tag
        let duration = (try? KeepAwakeDuration.parse(minutes)) ?? .indefinite
        state.keepAwakeManager?.start(duration: duration)
    }

    @objc private func keepAwakeStop() {
        state.keepAwakeManager?.stop(reason: .manual)
    }

    @objc private func keepAwakeRetryCleanup() {
        Task { @MainActor in
            await state.keepAwakeManager?.retryCleanup()
        }
    }

    @objc private func openKeepAwakeSettings() {
        onOpenSettings(.keepAwake)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func nsColor(for tint: KeepAwakeIconTint) -> NSColor? {
        switch tint {
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .none: return nil
        }
    }

    private func tooltipString(for kind: StatusBarTooltipKind) -> String {
        let s = state.l10n.s
        switch kind {
        case .inactive:
            return s.keepAwakeTooltipInactive
        case .inactiveWithError(let summary):
            return String(format: s.keepAwakeTooltipInactiveWithError, summary)
        case .activating:
            return s.keepAwakeTooltipActivating
        case .deactivating:
            return s.keepAwakeTooltipDeactivating
        case .activeTimed(let end):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return String(format: s.keepAwakeTooltipActiveTimed, formatter.string(from: end))
        case .activeIndefinite:
            return s.keepAwakeTooltipActiveIndefinite
        case .cleanupRequired:
            return s.keepAwakeTooltipCleanupRequired
        }
    }

    func showClipboardPanel() {
        if panel.isVisible {
            closePanel()
        }
        clipboardWindowController.toggleVisibility()
    }

    private func setupBlueDot(in button: NSStatusBarButton) {
        let dot = LockBadgeDotView(frame: .zero)
        dot.isHidden = true
        button.addSubview(dot)
        blueDotView = dot

        button.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleButtonFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: button
        )
        layoutLockBadge()
    }

    @objc private func handleButtonFrameChanged(_ notification: Notification) {
        layoutLockBadge()
    }

    private func updateLockBadgeVisibility(isLocked: Bool) {
        let shouldHide = isMainIconHiddenByMetrics || !isLocked
        blueDotView?.isHidden = shouldHide
        if !shouldHide {
            layoutLockBadge()
        }
    }

    private func layoutLockBadge() {
        guard let button = statusItem.button, let badge = blueDotView else { return }
        let dotSize = LockBadgeDotView.size
        let buttonBounds = button.bounds
        guard buttonBounds.width > 0 && buttonBounds.height > 0 else {
            badge.frame = NSRect(x: 14, y: 13, width: dotSize, height: dotSize)
            return
        }

        let iconWidth: CGFloat = 15
        let iconHeight: CGFloat = 15
        let iconX: CGFloat
        if button.imagePosition == .imageLeading {
            iconX = 4
        } else {
            iconX = max(0, (buttonBounds.width - iconWidth) / 2)
        }
        let iconY = max(0, (buttonBounds.height - iconHeight) / 2)

        let targetX = iconX + iconWidth - dotSize + 1
        let targetY = iconY + iconHeight - dotSize + 1
        badge.frame = NSRect(
            x: round(targetX),
            y: round(targetY),
            width: dotSize,
            height: dotSize
        )
    }

    @objc private func togglePopover() {
        if panel.isVisible {
            closePanel()
            return
        }
        // 竞态消解：点击状态栏按钮时 mouseDown 先令面板失焦关闭，紧随的
        // mouseUp action 到达时意图是「关闭」而非「重开」——短窗内的
        // 失焦关闭视为本次点击已消费（NSPopover transient 天然具备该语义）。
        if let dismissedAt = panelDismissedByFocusLossAt,
           Date().timeIntervalSince(dismissedAt) < 0.3 {
            panelDismissedByFocusLossAt = nil
            return
        }
        openPanel()
    }

    /// 打开面板：装配内容（首显测高）→ 一次性定位 → 显示并激活。
    /// NSWindow 无锚定跟随机制，此后的数值宽度变化不会移动面板。
    private func openPanel() {
        let totalHeight = installPanelContentIfNeeded()
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1512, height: 1384)
        let frame = ControlCenterPanelWindow.panelFrame(
            anchorScreenFrame: anchor,
            panelSize: NSSize(width: ControlCenterContentMetrics.panelWidth, height: totalHeight),
            visibleFrame: visibleFrame
        )
        panel.setFrame(frame, display: true)
        panelSizer?.pinTopEdge(frame.maxY)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        button.isHighlighted = true
        startEscapeKeyMonitor()
    }

    /// 关闭面板并清空会话（幂等）：停监听、复位按钮态、释放内容视图。
    func closePanel() {
        guard panel.isVisible || panel.contentViewController != nil else { return }
        stopEscapeKeyMonitor()
        statusItem.button?.isHighlighted = false
        panel.makeFirstResponder(nil)
        panel.contentView?.discardCursorRects()
        sizingContext?.endSession()
        sizingContext = nil
        panelSizer = nil
        panel.contentViewController = nil
        panel.contentView = nil
        panel.orderOut(nil)
    }

    /// 点击面板外/切换应用等失焦路径关闭（NSPopover transient 的自管等价物）。
    /// sheet 呈现期的失焦是「内部失焦」，豁免（且不记录 dismiss 时间戳，
    /// 避免污染 0.3s 竞态窗判断）。
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        guard panel.shouldCloseOnFocusLoss else { return }
        panelDismissedByFocusLossAt = Date()
        closePanel()
    }

    // MARK: - Escape 监听（面板可见期间）

    private func startEscapeKeyMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 53 else { return event }
            // sheet 呈现期间 Escape 交给 sheet 自身（取消/收起），不放行会
            // 把整个面板连同 sheet 一起关掉。
            guard self.panel.shouldCloseOnFocusLoss else { return event }
            self.closePanel()
            return nil
        }
    }

    private func stopEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
        escapeKeyMonitor = nil
    }

    // MARK: - Monitor Integration

    private func setupMonitorMetrics() {
        let sink = StatusBarMetricSink(statusItem: statusItem)
        metricSink = sink
        metricCoordinator = StatusBarMetricCoordinator(sink: sink)

        guard let monitor = state.monitor,
              let preferences = state.monitorPreferences else {
            clearMenuBarMetricsUI()
            return
        }

        applyMenuBarMetricsFromPreferences()

        monitor.$snapshot
            .combineLatest(preferences.$configuration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot, config in
                guard let self else { return }
                self.applyMenuBarMetricsFromPreferences(configuration: config)
                let isLocked = self.state.lockState?.isLocked == true
                guard FeatureRuntime.shared.isAvailable(.systemMonitor), config.isEnabled else {
                    self.lastMetricsMergedTitle = NSAttributedString(string: "")
                    self.lastMetricsSeparateGroups = []
                    self.lastMetricsSeparate = false
                    self.clearMenuBarMetricsUI(isLocked: isLocked)
                    self.applyComposedMainTitle(keepAwakeRender: self.lastKeepAwakeRender)
                    return
                }
                let metrics = config.menuBarMetricOrder.filter {
                    config.enabledMenuBarMetrics.contains($0)
                }
                let mergedTitle = MenuBarMetricRenderer.attributedTitle(
                    for: snapshot,
                    metrics: metrics,
                    configuration: config
                )
                let separateGroups = MenuBarMetricRenderer.attributedGroups(
                    for: snapshot,
                    metrics: metrics,
                    configuration: config
                )
                // active/transitional keep-awake 覆盖 hide-main（builder 已把 active 等标为 mainItemVisible=true）。
                let keepAwakeForcesVisible = self.lastKeepAwakeRender?.mainItemVisible == true
                    && self.state.keepAwakeManager.map { manager in
                        switch manager.state {
                        case .inactive: return false
                        case .active, .activating, .deactivating, .cleanupRequired: return true
                        }
                    } == true
                let hideMain = config.hideMainIconWithMetrics && !metrics.isEmpty && !keepAwakeForcesVisible
                self.isMainIconHiddenByMetrics = hideMain
                self.updateLockBadgeVisibility(isLocked: isLocked)
                self.lastMetricsMergedTitle = mergedTitle
                self.lastMetricsSeparateGroups = separateGroups
                self.lastMetricsSeparate = config.separateStatusItems
                // separate 模式：metrics 独立 item；countdown 仍写主 item。
                // 合并模式：coordinator 写 metrics base，随后 compose 叠加 countdown。
                self.metricCoordinator?.apply(
                    mergedTitle: config.separateStatusItems
                        ? NSAttributedString(string: "")
                        : mergedTitle,
                    separateGroups: separateGroups,
                    separate: config.separateStatusItems,
                    hideMainIcon: hideMain,
                    mainIcon: Self.menuBarIcon()
                )
                self.applyComposedMainTitle(keepAwakeRender: self.lastKeepAwakeRender)
            }
            .store(in: &monitorCancellables)
    }

    private func clearMenuBarMetricsUI(isLocked: Bool = false) {
        isMainIconHiddenByMetrics = false
        updateLockBadgeVisibility(isLocked: isLocked)
        metricCoordinator?.apply(
            mergedTitle: NSAttributedString(string: ""),
            separateGroups: [],
            separate: false,
            hideMainIcon: false,
            mainIcon: Self.menuBarIcon()
        )
    }

    // MARK: - 根据 availability + isEnabled 应用菜单栏采样需求
    private func applyMenuBarMetricsFromPreferences(
        configuration: MonitorConfiguration? = nil
    ) {
        guard let monitor = state.monitor,
              let preferences = state.monitorPreferences else { return }
        let config = configuration ?? preferences.configuration
        guard FeatureRuntime.shared.isAvailable(.systemMonitor), config.isEnabled else {
            monitor.setMenuBarMetrics([])
            return
        }
        monitor.setMenuBarMetrics(config.enabledMenuBarMetrics)
    }

    var hasPanelContent: Bool {
        panel.contentViewController != nil
    }

    /// Screen frame of the main menu bar status item button.
    /// Used by ShelfService to anchor the docked drop zone under the icon.
    func mainStatusItemScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// 控制中心尺寸上下文与适配器：面板打开期间存在；关闭即释放，
    /// 重新打开走全新会话（SPEC §7.2 关闭重开）。
    private var sizingContext: ControlCenterSizingContext?
    private var panelSizer: ControlCenterPanelSizer?

    /// 装配面板内容（首显测高流程原样保留），返回首显总高。
    /// 重复调用幂等：返回当前已装配内容高度。
    @discardableResult
    func installPanelContentIfNeeded() -> CGFloat {
        if let existing = panel.contentViewController {
            return existing.view.bounds.height
        }

        let context = ControlCenterSizingContext()
        context.availableTotalHeightProvider = { [weak self] in
            self?.panelAvailableHeight() ?? 1055
        }
        context.backingScaleProvider = { [weak self] in
            self?.statusItem.button?.window?.screen?.backingScaleFactor ?? 2
        }
        let sizer = ControlCenterPanelSizer(window: panel)
        context.beginSession(sizer: sizer)
        sizingContext = context
        panelSizer = sizer

        // 首显测高（SPEC §7.2.1）：显示之前以自然高度布局完成有效测量，
        // 避免「先 580 再缩短」的显示后补跳。
        context.beginInitialMeasurement()
        let controller = NSHostingController(
            rootView: AnyView(
                ControlCenterContainerView(
                    state: state,
                    onOpenSettings: { [onOpenSettings] tab in
                        onOpenSettings(tab)
                    },
                    sizingContext: context
                )
            )
        )
        // 单一尺寸路径（SPEC §5）：禁用 preferredContentSize 自动追踪，
        // 外壳几何只经 ControlCenterPanelSizer 提交。
        controller.sizingOptions = []
        let hostingView = controller.view
        hostingView.setFrameSize(
            NSSize(width: ControlCenterContentMetrics.panelWidth, height: 2000)
        )
        hostingView.layoutSubtreeIfNeeded()

        // 等待测量上报：onPreferenceChange 由 SwiftUI 在布局 pass 后的下一
        // runloop 拍派发（同步 layoutSubtreeIfNeeded 拿不到），泵 run loop
        // 至自然高度与 chrome 就绪；超预算走降级（viewport=580 上限）。
        let waitDeadline = Date().addingTimeInterval(0.4)
        var pumps = 0
        while !context.hasInitialMeasurement && Date() < waitDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            pumps += 1
        }
        ControlCenterSizingLog.log(
            "首显测高等待: \(context.hasInitialMeasurement ? "就绪" : "超时降级") pumps=\(pumps)"
        )
        let totalHeight = context.commitInitialMeasurement()
        // 自管窗口无 chrome 差：内容高度即窗口高度；frame 由 openPanel 定位。
        hostingView.setFrameSize(
            NSSize(width: ControlCenterContentMetrics.panelWidth, height: totalHeight)
        )
        panel.contentViewController = controller
        panel.applyContentCornerRadius(hostingView)
        return totalHeight
    }

    /// 当前锚点方向上面板可容纳的内容总高：
    /// 菜单栏锚点向下弹出 = 锚点下沿到屏幕可见区底部（SPEC §3.1 Havailable）。
    /// 锚点位于菜单栏内、在 visibleFrame 上方，方向不可写反（否则恒 ≤0
    /// 触发全链路降级）。
    private func panelAvailableHeight() -> CGFloat {
        guard
            let button = statusItem.button,
            let window = button.window,
            let screen = window.screen ?? NSScreen.main
        else {
            return NSScreen.main?.visibleFrame.height ?? 1055
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        return Self.availableHeight(anchorMinY: anchor.minY, visibleFrame: screen.visibleFrame)
    }

    /// 可用高度纯计算（可测）：锚点下沿 → 可见区底部，扣除顶边间隙与
    /// 阴影余量（自管窗口无箭头，仅 topGap 4 + 安全 4）。
    nonisolated static func availableHeight(anchorMinY: CGFloat, visibleFrame: CGRect) -> CGFloat {
        max(0, anchorMinY - visibleFrame.minY - 8)
    }

    /// 测试入口：直接触发设置回调，避免依赖 popover 内 SwiftUI 命中。
    func invokeOpenSettingsForTesting() {
        onOpenSettings(nil)
    }

    /// 测试入口：右键「打开保持唤醒设置」路径。
    func invokeOpenKeepAwakeSettingsForTesting() {
        onOpenSettings(.keepAwake)
    }
}

// MARK: - LockBadgeDotView

/// 菜单栏输入法锁定状态角标圆点：采用动态自绘制，在浅色与深色菜单栏下均保持高亮清晰与立体对比度。
final class LockBadgeDotView: NSView {
    static let size: CGFloat = 6.5

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: frameRect.origin.x, y: frameRect.origin.y, width: Self.size, height: Self.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let insetBounds = bounds.insetBy(dx: 0.5, dy: 0.5)

        // 1. 核心亮蓝色：深色模式采用明亮高饱和 #0A84FF，浅色模式采用 #007AFF
        let dotColor = isDark
            ? NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)

        // 2. 边框：暗色模式采用半透明亮白边缘确保在黑色背景与白色图钉旁清晰分离，浅色模式采用纯白外圈
        let strokeColor = isDark
            ? NSColor.white.withAlphaComponent(0.4)
            : NSColor.white.withAlphaComponent(0.9)

        context.setFillColor(dotColor.cgColor)
        context.fillEllipse(in: insetBounds)

        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(0.75)
        context.strokeEllipse(in: insetBounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
