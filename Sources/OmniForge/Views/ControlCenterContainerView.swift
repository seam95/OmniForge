import ApplicationServices
import SwiftUI

/// 控制中心内容区尺寸契约（SPEC §8.1）：宽度固定 380pt，页面内容 viewport
/// 固定 580pt；超出 viewport 的页面在各自内容区内部滚动，popover 打开期间
/// 不再由页面内容测高驱动尺寸变化。
enum ControlCenterContentMetrics {
    static let panelWidth: CGFloat = 380
    /// 页面内容 viewport 固定高度。
    static let viewportHeight: CGFloat = 580
    /// 空状态 / 不可用页的最小内容高度，避免空态区域过扁。
    static let emptyContentMinHeight: CGFloat = 120
}

struct ControlCenterContainerView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }
    @AppStorage(UserDefaultsKeys.lastControlCenterPanel)
    private var selectedPanelRawValue = MenuPanel.systemMonitor.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keepAwakeConfigError: String?
    @Namespace private var navIndicator
    // 监控面板的有状态对象提升到容器层：切走面板不再销毁，保留磁盘推出进度与已展开的进程指标。
    @StateObject private var monitorCoordinator = ProcessBreakdownCoordinator()
    @StateObject private var monitorDiskProtection = DiskProtectionService()
    // 监控/工具页路由由宿主持有：面板切换回来保留用户所在层级。
    @State private var monitorRoute: MonitorPanelRoute = .overview
    @State private var utilityRoute: UtilityToolsRoute = .list
    /// 当前展示面板（displayedRoute）：footer 的 route 相关样式只在交换点更新
    /// （SPEC §8.2.4），不读提前变化的请求 route。
    @State private var displayedPanel: MenuPanel = .systemMonitor

    var body: some View {
        let visiblePanels = MenuPanel.visibleCases(isAvailable: runtime.isAvailable)
        let recoveryModel = KeepAwakeRecoveryBannerModel.from(
            state: state.clamshellRecoveryCoordinator?.state
                ?? compositionRecoveryState,
            strings: state.l10n.s
        )

        VStack(spacing: 0) {
            KeepAwakeRecoveryBanner(model: recoveryModel) {
                Task { @MainActor in
                    await state.clamshellRecoveryCoordinator?.retry()
                }
            }

            if !visiblePanels.isEmpty {
                panelNavigation(visiblePanels: visiblePanels)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
            }

            panelContent(visiblePanels: visiblePanels)
                .frame(maxWidth: .infinity, alignment: .top)

            footer
        }
        .frame(width: ControlCenterContentMetrics.panelWidth)
        .background(
            Group {
                if colorScheme == .dark {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Theme.Stats.panelBackground
                }
            }
        )
        .onAppear { resolveSelection(in: visiblePanels) }
        .onChange(of: runtime.revision) { _, _ in
            resolveSelection(in: MenuPanel.visibleCases(isAvailable: runtime.isAvailable))
        }
        // popover 关闭（宿主销毁）：面板级采样需求清零；进程采样状态由监控
        // 内容视图的 onDisappear 折叠。菜单栏/告警需求由 manager 内部继续维护。
        .onDisappear {
            state.monitor?.setPanelDemand(.none)
        }
        .omniNoFocusRing()
    }

    /// AppState 尚未注入 coordinator 时的安全默认。
    private var compositionRecoveryState: ClamshellRecoveryUIState {
        .idle
    }

    /// 对齐 macOS 控制中心分段导航：紧凑等分单元 + 柔和背景 + 选中 accent 悬浮底块。
    private func panelNavigation(visiblePanels: [MenuPanel]) -> some View {
        HStack(spacing: 2) {
            ForEach(visiblePanels) { panel in
                let isActive = selectedPanel == panel
                let title = panel.navTitle(in: state.l10n.s)
                ControlCenterNavButton(
                    panel: panel,
                    title: title,
                    isActive: isActive,
                    activeFill: navigationActiveFill,
                    colorScheme: colorScheme,
                    indicatorNamespace: navIndicator,
                    indicatorAnimation: PageSwitchMotionToken.selectionIndicator(
                        reduceMotion: reduceMotion
                    )
                ) {
                    // 动画统一由 value 驱动（对齐主浮窗 tab 模式）：
                    // 点击、resolveSelection 等任意赋值路径下底块与内容同享一套转场。
                    selectedPanelRawValue = panel.rawValue
                }
            }
        }
        .animation(
            PageSwitchMotionToken.selectionIndicator(reduceMotion: reduceMotion),
            value: selectedPanelRawValue
        )
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(navigationTrackFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(navigationTrackBorder, lineWidth: 0.8)
        )
    }

    /// 页面内容统一 Host（SPEC §6）：单活动树、分阶段淡出后淡入；
    /// 表面样式（白底/灰底）由 Host 持有、只在交换点更新。
    private func panelContent(visiblePanels: [MenuPanel]) -> some View {
        PageSwitchHost(
            requestedRoute: MenuPanel.resolvedSelection(selectedPanel, in: visiblePanels)
                ?? .systemMonitor,
            semantics: { _, _ in .peer },
            surface: panelSurface,
            onDisplayedSurfaceChange: { panel, _ in
                displayedPanel = panel
                coordinateMonitorDemand(for: panel)
            }
        ) { panel in
            // 固定 viewport 内部滚动：页面内容不再向壳层上报高度（SPEC §8.1.3/§8.1.5）。
            ScrollView(showsIndicators: false) {
                panelCase(panel)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: ControlCenterContentMetrics.viewportHeight)
        .clipped()
    }

    /// 监控采样需求由「popover 是否打开 + 当前展示 route」驱动（SPEC §9.1.1）：
    /// 展示监控页时按配置聚合断言，切到其他面板清面板需求（菜单栏/告警需求
    /// 由 manager 内部合并，不受影响）。进程采样（展开的排名）恢复与折叠由
    /// 监控内容视图在挂载/卸载时管理（此时 onToggle 已绑定）。
    private func coordinateMonitorDemand(for panel: MenuPanel) {
        guard let monitor = state.monitor,
              let preferences = state.monitorPreferences else { return }

        let isActivePanel = panel == .systemMonitor
        let demand = isActivePanel
            ? MonitorContainerView.demand(for: preferences.configuration)
            : .none
        monitor.setPanelDemand(
            MonitorPanelDemandGate.resolve(
                demand,
                isEnabled: preferences.configuration.isEnabled,
                isAvailable: runtime.isAvailable(.systemMonitor)
            )
        )
    }

    /// 页面表面样式（SPEC §8.2）：token/供应商页浅色白底（平面白底风格）；
    /// 其余透明——监控 overview 白底由监控内层 route 持有（层级迁移见阶段 7）。
    private func panelSurface(_ panel: MenuPanel) -> PageSurface {
        if (panel == .tokenUsage || panel == .providerSwitch) && colorScheme == .light {
            return PageSurface(background: .white)
        }
        return .clear
    }

    @ViewBuilder
    private func panelCase(_ panel: MenuPanel) -> some View {
        switch panel {
            case .systemMonitor:
                if let monitor = state.monitor,
                   let preferences = state.monitorPreferences,
                   runtime.isAvailable(.systemMonitor) {
                    MonitorContainerView(
                            coordinator: monitorCoordinator,
                            diskProtection: monitorDiskProtection,
                            route: $monitorRoute,
                            monitor: monitor,
                            configuration: preferences.configuration,
                            strings: state.l10n.s,
                            onDemandChange: { demand in
                                monitor.setPanelDemand(
                                    MonitorPanelDemandGate.resolve(
                                        demand,
                                        isEnabled: preferences.configuration.isEnabled,
                                        isAvailable: runtime.isAvailable(.systemMonitor)
                                    )
                                )
                            },
                            onExpandedMetric: { monitor.setExpandedProcessMetric($0) },
                            onStartSpeedTest: { monitor.startSpeedTest() },
                            onOpenSettings: { onOpenSettings(nil) },
                            showsSettingsAction: false,
                            onRefresh: { forceProcess in
                                monitor.refreshNow(forceProcess: forceProcess)
                            }
                        )
                } else {
                    unavailablePanel
                }
            case .tokenUsage:
                if let manager = state.tokenUsageManager,
                   let preferences = state.tokenUsagePreferences,
                   runtime.isAvailable(.tokenUsage) {
                    TokenUsagePanelView(
                        manager: manager,
                        preferences: preferences,
                        balanceManager: state.deepSeekBalanceManager,
                        strings: state.l10n.s,
                        onOpenSettings: onOpenSettings
                    )
                } else {
                    unavailablePanel
                }
            case .keepAwake:
                keepAwakePanel
            case .clipboard:
                UtilityToolsView(strings: state.l10n.s, route: $utilityRoute)
            case .providerSwitch:
                if let manager = state.providerSwitchManager,
                   runtime.isAvailable(.providerSwitch) {
                    ProviderSwitchSettingsView(
                        manager: manager,
                        strings: state.l10n.s,
                        presentation: .menuBar,
                        onOpenSettings: onOpenSettings
                    )
                } else {
                    unavailablePanel
                }
            }
    }

    @ViewBuilder
    private var keepAwakePanel: some View {
        if let manager = state.keepAwakeManager, runtime.isAvailable(.keepAwake) {
            // 倒计时由 KeepAwakeControlView 内部基于 countdownEndDate 局部刷新，避免整页秒级重建。
            let blocksStart = state.clamshellRecoveryCoordinator?.blocksKeepAwakeStart ?? false
            let presentation = KeepAwakeControlPresentationBuilder.build(
                session: manager.state,
                clamshell: manager.clamshellState,
                lastError: manager.lastOperationError,
                blocksStart: blocksStart,
                isFeatureAvailable: true,
                now: Date(),
                pointerError: manager.pointerActivityError,
                batteryError: manager.batteryMonitoringError,
                strings: state.l10n.s
            )
            KeepAwakeControlView(
                presentation: presentation,
                config: makeKeepAwakeConfigBindings(manager: manager),
                strings: state.l10n.s,
                onStart: { manager.start() },
                onStop: { manager.stop(reason: .manual) },
                onRetryCleanup: {
                    Task { await manager.retryCleanup() }
                },
                onExtend: { minutes in manager.extend(byMinutes: minutes) },
                onSetDuration: { duration in manager.setDuration(duration) }
            )
        } else {
            KeepAwakeControlView(
                presentation: KeepAwakeControlPresentationBuilder.build(
                    session: .inactive,
                    clamshell: .off,
                    lastError: nil,
                    blocksStart: false,
                    isFeatureAvailable: false,
                    strings: state.l10n.s
                ),
                config: .previewDisabled,
                strings: state.l10n.s
            )
        }
    }

    private func makeKeepAwakeConfigBindings(manager: KeepAwakeManager) -> KeepAwakeControlConfigBindings {
        let defaults = UserDefaults.standard
        return KeepAwakeControlConfigBindings(
            defaultDurationMinutes: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes) == nil {
                        return 0
                    }
                    return defaults.integer(forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
                },
                set: { newValue in
                    do {
                        _ = try KeepAwakeDuration.parse(newValue)
                        defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeDefaultDurationMinutes)
                        keepAwakeConfigError = nil
                    } catch {
                        keepAwakeConfigError = String(describing: error)
                    }
                }
            ),
            autoStart: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeAutoStart) == nil { return false }
                    return defaults.bool(forKey: UserDefaultsKeys.keepAwakeAutoStart)
                },
                set: { defaults.set($0, forKey: UserDefaultsKeys.keepAwakeAutoStart) }
            ),
            mouseJiggleEnabled: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled) == nil {
                        return false
                    }
                    return defaults.bool(forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled)
                },
                set: { newValue in
                    defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeMouseJiggleEnabled)
                    manager.resyncPointerActivityFromConfiguration()
                }
            ),
            mouseJiggleIntervalMinutes: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes) == nil {
                        return 5
                    }
                    return defaults.integer(forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
                },
                set: { newValue in
                    do {
                        _ = try KeepAwakePointerInterval.parse(newValue)
                        defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeMouseJiggleIntervalMinutes)
                        keepAwakeConfigError = nil
                        manager.resyncPointerActivityFromConfiguration()
                    } catch {
                        keepAwakeConfigError = String(describing: error)
                    }
                }
            ),
            clamshellPreferred: Binding(
                get: {
                    if defaults.object(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred) == nil {
                        return false
                    }
                    return defaults.bool(forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
                },
                set: { newValue in
                    defaults.set(newValue, forKey: UserDefaultsKeys.keepAwakeClamshellPreferred)
                    Task { await manager.setClamshellPreferred(newValue) }
                }
            ),
            onRequestAccessibility: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            },
            onOpenKeepAwakeSettings: {
                onOpenSettings(.keepAwake)
            },
            configError: keepAwakeConfigError
        )
    }

    private var unavailablePanel: some View {
        Text(state.l10n.s.controlcenterEmpty)
            .font(Theme.Stats.font12Medium)
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(
                maxWidth: .infinity,
                minHeight: ControlCenterContentMetrics.emptyContentMinHeight,
                alignment: .center
            )
    }

    /// 监控、token、供应商页为平面白底风格（对齐设计稿）：footer 与内容区同底、顶部发丝线分隔、
    /// 按钮用主色；其余面板维持面板灰底默认样式。
    private var footer: some View {
        let flat = displayedPanel == .systemMonitor || displayedPanel == .tokenUsage || displayedPanel == .providerSwitch
        let tint = flat ? MonitorOverviewPalette.primary(colorScheme) : nil

        // footer 几何跨面板恒定（SPEC §3.1.3/§8.1）：flat 发丝线经 overlay 叠加，
        // 不占布局高度——非 flat 面板不再因少 1pt 分隔线改变 popover 总高。
        return HStack {
            FooterButton(
                    label: state.l10n.s.settingsTitle,
                    systemImage: "gearshape",
                    tint: tint
                ) {
                    onOpenSettings(nil)
                }

                Spacer()

                // Token 页底栏右位为「刷新」；其余面板保持「退出」（UI 稿 4.2）。
                // 手动刷新穿透内存/磁盘新鲜缓存，但 429 冷却不可穿透（#03）。
                if displayedPanel == .tokenUsage {
                    FooterButton(label: state.l10n.s.tokenRefresh, systemImage: "arrow.clockwise", tint: tint) {
                        state.tokenUsageManager?.refreshNow(force: true)
                        state.deepSeekBalanceManager?.refreshNow()
                    }
                } else {
                    FooterButton(
                        label: state.l10n.s.actionQuit,
                        systemImage: flat ? "rectangle.portrait.and.arrow.right" : nil,
                        tint: tint
                    ) {
                        NSApp.terminate(nil)
                    }
                }
            }
        .frame(height: 36)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(flat && colorScheme == .light ? Color.white : Color.clear)
        .overlay(alignment: .top) {
            if flat {
                Rectangle()
                    .fill(MonitorOverviewPalette.hairline(colorScheme))
                    .frame(height: 1)
            }
        }
    }

    private func resolveSelection(in visiblePanels: [MenuPanel]) {
        guard let resolved = MenuPanel.resolvedSelection(selectedPanel, in: visiblePanels) else { return }
        selectedPanelRawValue = resolved.rawValue
    }

    private var selectedPanel: MenuPanel? {
        MenuPanel(rawValue: selectedPanelRawValue)
    }

    private var navigationActiveFill: Color {
        colorScheme == .light ? Color.white : Color.white.opacity(0.14)
    }

    /// 不透明 popover 底上，用 controlFill 比半透明 cardFill 更接近截图胶囊轨。
    private var navigationTrackFill: Color {
        colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06)
    }

    private var navigationTrackBorder: Color {
        colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08)
    }
}

private struct ControlCenterNavButton: View {
    /// 选中底块 matchedGeometry 标识：同 id 全导航仅一处激活，底块在按钮间平滑滑移。
    private static let activeIndicatorID = "control-center-nav-active"

    let panel: MenuPanel
    let title: String
    let isActive: Bool
    let activeFill: Color
    let colorScheme: ColorScheme
    let indicatorNamespace: Namespace.ID
    /// 选中底块滑移动画（Reduce Motion 下降级为透明度过渡）。
    var indicatorAnimation: Animation = PageSwitchMotionToken.selectionIndicator(reduceMotion: false)
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // ViewThatFits 降级：等分单元放不下"图标+文字"时隐藏图标仅留文字，
            // 叠加 minimumScaleFactor 兜底，保证窄面板下标题永不折行、尽量不缩放。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: panel.symbolName)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(title)
                        .font(Theme.Stats.font12Medium)
                }
                Text(title)
                    .font(Theme.Stats.font12Medium)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? (colorScheme == .light ? Theme.Stats.text1 : Color.white) : (isHovered ? (colorScheme == .light ? Theme.Stats.text1 : Color.primary) : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary)))
        .background(
            ZStack {
                // 选中底块：matchedGeometry 让矩形从上一个按钮滑移过来，而非就地出现。
                if isActive {
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(activeFill)
                        .shadow(color: Color.black.opacity(colorScheme == .light ? 0.06 : 0.0), radius: 2, x: 0, y: 1)
                        .matchedGeometryEffect(id: Self.activeIndicatorID, in: indicatorNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
                        .transition(.opacity)
                }
            }
        )
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}


/// Panel demand must not restart sampling when FeatureHub is unavailable or monitoring is disabled.
enum MonitorPanelDemandGate {
    static func resolve(
        _ demand: MonitorDemand,
        isEnabled: Bool = true,
        isAvailable: Bool
    ) -> MonitorDemand {
        isAvailable && isEnabled ? demand : .none
    }
}
