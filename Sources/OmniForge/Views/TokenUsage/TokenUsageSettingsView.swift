import SwiftUI

/// 「Token 用量」设置页 — 两态：未安装仅安装开关；已安装为 [通用][提供商][告警] 子分段。
/// 通用：菜单栏显示 / 限额刷新间隔 / 限额显示 / 用量统计周期默认；
/// 提供商：5 家凭证状态行 + 「如何配置」引导；告警：两个开关 + 通知权限入口（引擎由 #11 接入）。
struct TokenUsageSettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtime = FeatureRuntime.shared
    @State private var section: TokenUsageSettingsSection = .general

    private var isInstalled: Bool {
        runtime.isAvailable(.tokenUsage)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isInstalled {
                uninstalledContent
            } else if let preferences = state.tokenUsagePreferences,
                      let manager = state.tokenUsageManager {
                Picker("", selection: $section) {
                    ForEach(TokenUsageSettingsSection.allCases) { item in
                        Text(item.title(in: state.l10n.s)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageSegment.rawValue)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider()

                Group {
                    switch section {
                    case .general:
                        TokenUsageGeneralSettingsView(
                            preferences: preferences,
                            strings: state.l10n.s
                        )
                    case .providers:
                        TokenUsageProvidersSettingsView(
                            manager: manager,
                            strings: state.l10n.s
                        )
                    case .alerts:
                        TokenUsageAlertsSettingsView(
                            preferences: preferences,
                            strings: state.l10n.s
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var uninstalledContent: some View {
        Form {
            Section {
                Toggle(state.l10n.s.featureHubNameTokenUsage, isOn: Binding(
                    get: { false },
                    set: { runtime.setAvailable(.tokenUsage, $0) }
                ))
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageEnabled.rawValue)
            } footer: {
                Text(state.l10n.s.tokenSettingsCaption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPageStyle()
    }
}

/// 通用：菜单栏显示 / 限额刷新间隔 / 限额显示 / 用量统计周期默认。
struct TokenUsageGeneralSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    let strings: Strings

    var body: some View {
        Form {
            Section(strings.tokenSettingsMenuBarMode) {
                Picker(strings.tokenSettingsMenuBarMode, selection: Binding(
                    get: { preferences.configuration.menuBarMode },
                    set: { mode in preferences.update { $0.menuBarMode = mode } }
                )) {
                    Text(strings.tokenSettingsMenuBarToday).tag(TokenUsageMenuBarMode.todayTokens)
                    Text(strings.tokenSettingsMenuBarSession).tag(TokenUsageMenuBarMode.sessionPercent)
                    Text(strings.tokenSettingsMenuBarOff).tag(TokenUsageMenuBarMode.hidden)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageMenuBarMode.rawValue)
            }

            Section(strings.tokenSettingsRefreshInterval) {
                Picker(strings.tokenSettingsRefreshInterval, selection: Binding(
                    get: { preferences.configuration.limitRefreshMinutes },
                    set: { minutes in try? preferences.setLimitRefreshMinutes(minutes) }
                )) {
                    ForEach(TokenUsageConfiguration.allowedRefreshIntervals, id: \.self) { minutes in
                        Text(String(format: strings.tokenSettingsRefreshMinuteFormat, minutes))
                            .tag(minutes)
                    }
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageRefreshInterval.rawValue)
            }

            Section(strings.tokenSettingsLimitsDisplay) {
                Picker(strings.tokenSettingsLimitsDisplay, selection: Binding(
                    get: { preferences.configuration.limitsDisplayMode },
                    set: { mode in preferences.update { $0.limitsDisplayMode = mode } }
                )) {
                    Text(strings.tokenSettingsLimitsUsed).tag(TokenUsageLimitsDisplay.used)
                    Text(strings.tokenSettingsLimitsRemaining).tag(TokenUsageLimitsDisplay.remaining)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageLimitsDisplay.rawValue)
            }

            Section(strings.tokenSettingsDefaultPeriod) {
                Picker(strings.tokenSettingsDefaultPeriod, selection: Binding(
                    get: { preferences.configuration.usagePeriodDefault },
                    set: { period in preferences.update { $0.usagePeriodDefault = period } }
                )) {
                    ForEach(TokenUsagePeriod.allCases) { period in
                        Text(period.title(in: strings)).tag(period)
                    }
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageDefaultPeriod.rawValue)
            }
        }
        .settingsPageStyle()
    }
}

/// 提供商：5 家各一行凭证状态；未配置给「如何配置 ›」展开引导。
struct TokenUsageProvidersSettingsView: View {
    @ObservedObject var manager: TokenUsageManager
    let strings: Strings
    @State private var expandedProviders: Set<TokenUsageProvider> = []

    var body: some View {
        Form {
            Section(strings.tokenSettingsProvidersSection) {
                ForEach(TokenUsageProvider.allCases) { provider in
                    providerRow(provider)
                }
            }
        }
        .settingsPageStyle()
    }

    @ViewBuilder
    private func providerRow(_ provider: TokenUsageProvider) -> some View {
        let limits = manager.limits[provider]
        let statusText = TokenUsageProviderStatusBuilder.statusText(limits: limits, strings: strings)
        let showsGuide = TokenUsageProviderStatusBuilder.showsConfigureGuide(limits)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider.accentColor)
                    .frame(width: 8, height: 8)
                Text(provider.displayName)
                Spacer()
                if let statusText {
                    if showsGuide {
                        Button {
                            toggleExpanded(provider)
                        } label: {
                            HStack(spacing: 4) {
                                Text(statusText)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    } else {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showsGuide && expandedProviders.contains(provider) {
                Text(TokenUsageProviderStatusBuilder.configureHint(for: provider, strings: strings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageProviderState(provider))
    }

    private func toggleExpanded(_ provider: TokenUsageProvider) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
    }
}

/// 告警：会话窗 ≥85% / 步速超前 开关（本票只做 UI 与持久化，引擎由 #11 接入）+ 通知权限申请入口。
struct TokenUsageAlertsSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject private var permissions = Permissions.shared
    let strings: Strings

    var body: some View {
        Form {
            Section(strings.tokenSettingsAlertsSection) {
                Toggle(strings.tokenSettingsSessionAlert, isOn: alertBinding(\.sessionLimitAlertEnabled))
                    .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageSessionAlert.rawValue)
                Toggle(strings.tokenSettingsPaceAlert, isOn: alertBinding(\.paceOverrunAlertEnabled))
                    .accessibilityIdentifier(SettingsAccessibilityID.tokenUsagePaceAlert.rawValue)
            }

            Section {
                HStack {
                    Text(strings.tokenSettingsRequestPermission)
                    Spacer()
                    if permissions.notifications {
                        Text(strings.tokenSettingsPermissionGranted)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(strings.tokenSettingsPermissionDenied)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(strings.settingsGrantAccess) {
                            permissions.requestAccess(for: .notifications)
                        }
                        .controlSize(.small)
                    }
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageRequestPermission.rawValue)
            }
        }
        .settingsPageStyle()
    }

    private func alertBinding(_ keyPath: WritableKeyPath<TokenUsageConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences.configuration[keyPath: keyPath] },
            set: { enabled in preferences.update { $0[keyPath: keyPath] = enabled } }
        )
    }
}
