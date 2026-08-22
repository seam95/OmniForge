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
                // 图标与指标之间留 1 个空格（有图标时）
                let title = NSMutableAttributedString()
                if !hideMainIcon {
                    title.append(NSAttributedString(string: " "))
                }
                title.append(mergedTitle)
                mainButton.attributedTitle = title
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
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let state: AppState
    private let clipboardWindowController: ClipboardWindowController
    /// 打开设置；tab=nil 表示默认页，`.keepAwake` 由右键菜单使用。
    private let onOpenSettings: (SettingsToolbarTab?) -> Void
    private var cancellable: AnyCancellable?
    private var blueDotView: NSView?
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
    /// Token 菜单栏贡献（#06）：独立状态项，与 systemMonitor 管线互不干扰。
    private var tokenMenuItem: NSStatusItem?
    private var tokenMenuBarCancellables = Set<AnyCancellable>()
    private var lastTokenMenuBarRender: TokenUsageMenuBarRender?

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

        let popover = NSPopover()
        popover.behavior = .transient
        self.popover = popover

        super.init()
        popover.delegate = self

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

        rebindFeatureObservers()
        FeatureRuntime.shared.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebindFeatureObservers()
            }
            .store(in: &featureCancellables)
    }

    private func rebindFeatureObservers() {
        cancellable = nil
        monitorCancellables.removeAll()

        if let lockState = state.lockState {
            cancellable = lockState.$isLocked
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLocked in
                    guard let self else { return }
                    self.blueDotView?.isHidden = self.isMainIconHiddenByMetrics || !isLocked
                }
            blueDotView?.isHidden = isMainIconHiddenByMetrics || !lockState.isLocked
        } else {
            blueDotView?.isHidden = true
        }

        setupMonitorMetrics()
        setupKeepAwakeStatusBar()
        setupTokenUsageMenuBar()
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
        blueDotView?.isHidden = !render.showLockBadge || isMainIconHiddenByMetrics

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
                }
            }
            return
        }
        button.attributedTitle = composed
        button.imagePosition = .imageLeading
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
        guard hasKeepAwake || hasPinsMenu || render.includeQuit else {
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
        if popover.isShown {
            popover.performClose(nil)
        }
        clipboardWindowController.toggleVisibility()
    }

    private func setupBlueDot(in button: NSStatusBarButton) {
        let dotSize: CGFloat = 6
        let dot = NSView(frame: NSRect(
            x: button.bounds.maxX - dotSize - 4,
            y: button.bounds.maxY - dotSize - 4,
            width: dotSize,
            height: dotSize
        ))
        dot.wantsLayer = true
        dot.layer = CALayer()
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.layer?.cornerRadius = dotSize / 2
        dot.isHidden = true
        button.addSubview(dot)
        blueDotView = dot
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            installPopoverContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
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
                self.blueDotView?.isHidden = hideMain || !isLocked
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
        blueDotView?.isHidden = !isLocked
        metricCoordinator?.apply(
            mergedTitle: NSAttributedString(string: ""),
            separateGroups: [],
            separate: false,
            hideMainIcon: false,
            mainIcon: Self.menuBarIcon()
        )
    }

    // MARK: - Token 菜单栏贡献（#06，独立于 systemMonitor 管线）

    /// 订阅 token 用量快照 + 菜单栏模式；仅当 tokenUsage 已安装且偏好可读时接线。
    /// 状态项独立创建/移除，不触碰 monitor metrics 路径。
    private func setupTokenUsageMenuBar() {
        tokenMenuBarCancellables.removeAll()
        lastTokenMenuBarRender = nil
        guard let prefs = state.tokenUsagePreferences,
              FeatureRuntime.shared.isAvailable(.tokenUsage),
              state.tokenUsageManager != nil else {
            removeTokenMenuItem()
            return
        }
        updateTokenUsageMenuBar(
            mode: prefs.configuration.menuBarMode,
            overview: state.tokenUsageManager?.usageOverview
        )

        // @Published 在 willSet 阶段先发新值再写属性：sink 内不得回读同一属性，
        // 直接用管线发送的值作为渲染输入（对照值读另一边稳定属性）。
        prefs.$configuration
            .map(\.menuBarMode)
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.updateTokenUsageMenuBar(
                    mode: mode,
                    overview: self?.state.tokenUsageManager?.usageOverview
                )
            }
            .store(in: &tokenMenuBarCancellables)

        state.tokenUsageManager?.$usageOverview
            .sink { [weak self] overview in
                self?.updateTokenUsageMenuBar(
                    mode: self?.state.tokenUsagePreferences?.configuration.menuBarMode
                        ?? .hidden,
                    overview: overview
                )
            }
            .store(in: &tokenMenuBarCancellables)
    }

    /// 用量快照 / 偏好 / 安装态任意变化后重算渲染状态（相等短路防抖动）。
    private func updateTokenUsageMenuBar(mode: TokenUsageMenuBarMode, overview: TokenUsageOverview?) {
        let render = TokenUsageMenuBarRenderer.render(
            isFeatureAvailable: FeatureRuntime.shared.isAvailable(.tokenUsage),
            overview: overview,
            mode: mode,
            label: state.l10n.s.tokenMenuBarTodayLabel
        )
        guard render != lastTokenMenuBarRender else { return }
        lastTokenMenuBarRender = render
        applyTokenUsageMenuBar(render)
    }

    private func applyTokenUsageMenuBar(_ render: TokenUsageMenuBarRender) {
        guard let block = render.block else {
            // 无数据/关闭：整体隐藏（不保留 0k 占位）。
            tokenMenuItem?.isVisible = false
            return
        }
        let item: NSStatusItem
        if let existing = tokenMenuItem {
            item = existing
        } else {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            tokenMenuItem = created
            item = created
        }
        guard let button = item.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = MenuBarMetricRenderer.attributedTitle(for: block)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.cell?.lineBreakMode = .byClipping
        button.cell?.usesSingleLineMode = false
        item.isVisible = true
    }

    private func removeTokenMenuItem() {
        if let item = tokenMenuItem {
            NSStatusBar.system.removeStatusItem(item)
            tokenMenuItem = nil
        }
    }

    /// 根据 availability + isEnabled 应用或清空菜单栏采样需求
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

    var hasPopoverContent: Bool {
        popover.contentViewController != nil
    }

    /// Screen frame of the main menu bar status item button.
    /// Used by ShelfService to anchor the docked drop zone under the icon.
    func mainStatusItemScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func installPopoverContentIfNeeded() {
        guard popover.contentViewController == nil else { return }
        let controller = NSHostingController(
            rootView: AnyView(
                ControlCenterContainerView(
                    state: state,
                    onOpenSettings: { [onOpenSettings] tab in
                        onOpenSettings(tab)
                    }
                )
            )
        )
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// 测试入口：直接触发设置回调，避免依赖 popover 内 SwiftUI 命中。
    func invokeOpenSettingsForTesting() {
        onOpenSettings(nil)
    }

    /// 测试入口：右键「打开保持唤醒设置」路径。
    func invokeOpenKeepAwakeSettingsForTesting() {
        onOpenSettings(.keepAwake)
    }

    /// 测试入口：最近一次 token 菜单栏渲染状态（nil = 未渲染过）。
    var tokenMenuBarRenderForTesting: TokenUsageMenuBarRender? { lastTokenMenuBarRender }

    /// 测试入口：token 菜单栏状态项是否可见（nil = 状态项不存在）。
    var tokenMenuBarItemVisibleForTesting: Bool? { tokenMenuItem?.isVisible }
}
