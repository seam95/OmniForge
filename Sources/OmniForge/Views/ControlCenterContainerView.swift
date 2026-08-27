import ApplicationServices
import SwiftUI

/// 控制中心内容区高度策略：所有页按内容自适应收缩并设滚动上限。
enum ControlCenterContentMetrics {
    static let panelWidth: CGFloat = 380
    /// 各页滚动上限。
    static let maxContentHeight: CGFloat = 580
    /// 空状态 / 不可用页的最小内容高度，避免 popover 过扁。
    static let emptyContentMinHeight: CGFloat = 120

    /// 所有页均支持自适应内容高度。
    static func usesSelfSizedFixedHeight(_ panel: MenuPanel) -> Bool {
        false
    }

    /// 根据测得的内容高度计算展示高度（不超过上限）。
    static func resolvedHeight(contentHeight: CGFloat, maxHeight: CGFloat = maxContentHeight) -> CGFloat {
        guard contentHeight.isFinite, contentHeight > 0 else { return 0 }
        return min(contentHeight, maxHeight)
    }
}

/// 按子视图固有高度收缩 popover；超过 `maxHeight` 后在限高内滚动。
private struct AdaptiveHeightScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let displayHeight = ControlCenterContentMetrics.resolvedHeight(
            contentHeight: contentHeight,
            maxHeight: maxHeight
        )
        ScrollView(showsIndicators: false) {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: AdaptiveContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
        }
        .onPreferenceChange(AdaptiveContentHeightKey.self) { contentHeight = $0 }
        // 未测到前不强制高度，避免首帧被撑到 maxHeight。
        .frame(height: displayHeight > 0 ? displayHeight : nil, alignment: .top)
    }
}

private struct AdaptiveContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ControlCenterContainerView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }
    @AppStorage(UserDefaultsKeys.lastControlCenterPanel)
    private var selectedPanelRawValue = MenuPanel.systemMonitor.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var keepAwakeConfigError: String?

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
                .frame(height: 36)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
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
                    colorScheme: colorScheme
                ) {
                    withAnimation(Theme.Animation.spring) {
                        selectedPanelRawValue = panel.rawValue
                    }
                }
            }
        }
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

    @ViewBuilder
    private func panelContent(visiblePanels: [MenuPanel]) -> some View {
        if let panel = MenuPanel.resolvedSelection(selectedPanel, in: visiblePanels) {
            switch panel {
            case .systemMonitor:
                if let monitor = state.monitor,
                   let preferences = state.monitorPreferences,
                   runtime.isAvailable(.systemMonitor) {
                    AdaptiveHeightScroll(maxHeight: ControlCenterContentMetrics.maxContentHeight) {
                        MonitorContainerView(
                            snapshot: monitor.snapshot,
                            history: monitor.history,
                            processState: monitor.processState,
                            speedTestState: monitor.speedTestState,
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
                    }
                } else {
                    unavailablePanel
                }
            case .tokenUsage:
                if let manager = state.tokenUsageManager,
                   let preferences = state.tokenUsagePreferences,
                   runtime.isAvailable(.tokenUsage) {
                    AdaptiveHeightScroll(maxHeight: ControlCenterContentMetrics.maxContentHeight) {
                        TokenUsagePanelView(
                            manager: manager,
                            preferences: preferences,
                            balanceManager: state.deepSeekBalanceManager,
                            strings: state.l10n.s,
                            onOpenSettings: onOpenSettings
                        )
                    }
                } else {
                    unavailablePanel
                }
            case .keepAwake:
                AdaptiveHeightScroll(maxHeight: ControlCenterContentMetrics.maxContentHeight) {
                    keepAwakePanel
                }
            case .clipboard:
                AdaptiveHeightScroll(maxHeight: ControlCenterContentMetrics.maxContentHeight) {
                    UtilityToolsView(strings: state.l10n.s)
                }
            case .providerSwitch:
                if let manager = state.providerSwitchManager,
                   runtime.isAvailable(.providerSwitch) {
                    AdaptiveHeightScroll(maxHeight: ControlCenterContentMetrics.maxContentHeight) {
                        ProviderSwitchSettingsView(
                            manager: manager,
                            strings: state.l10n.s,
                            presentation: .menuBar,
                            onOpenSettings: onOpenSettings
                        )
                    }
                } else {
                    unavailablePanel
                }
            }
        } else {
            unavailablePanel
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

    private var footer: some View {
        HStack {
            FooterButton(label: state.l10n.s.settingsTitle, systemImage: "gearshape") {
                onOpenSettings(nil)
            }

            Spacer()

            // Token 页底栏右位为「刷新」；其余面板保持「退出」（UI 稿 4.2）。
            // 手动刷新穿透内存/磁盘新鲜缓存，但 429 冷却不可穿透（#03）。
            if selectedPanel == .tokenUsage {
                FooterButton(label: state.l10n.s.tokenRefresh, systemImage: "arrow.clockwise") {
                    state.tokenUsageManager?.refreshNow(force: true)
                    state.deepSeekBalanceManager?.refreshNow()
                }
            } else {
                FooterButton(label: state.l10n.s.actionQuit, systemImage: nil) {
                    NSApp.terminate(nil)
                }
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
    let panel: MenuPanel
    let title: String
    let isActive: Bool
    let activeFill: Color
    let colorScheme: ColorScheme
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
        .focusEffectDisabled()
        .foregroundStyle(isActive ? (colorScheme == .light ? Theme.Stats.text1 : Color.white) : (isHovered ? (colorScheme == .light ? Theme.Stats.text1 : Color.primary) : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary)))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                .fill(isActive ? activeFill : (isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04) : Color.clear))
                .shadow(color: Color.black.opacity(isActive && colorScheme == .light ? 0.06 : 0.0), radius: 2, x: 0, y: 1)
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
