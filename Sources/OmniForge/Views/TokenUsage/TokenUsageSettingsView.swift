import SwiftUI

/// 「Token 用量」设置页 — 两态：未安装仅安装开关；已安装为 [通用][提供商][告警] 子分段。
/// 通用：菜单栏显示 / 限额刷新间隔 / 用量统计周期默认（限额口径与显隐排序在限额卡片齿轮弹层）；
/// 提供商：15 家凭证状态行 + 「如何配置」展开引导（DeepSeek / Trae CN / OpenCode / 方舟展开为凭证配置卡）；
/// 告警：会话窗阈值（70/85/90/95 可配）与步速超前开关 + 通知权限入口。
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
                            preferences: preferences,
                            manager: manager,
                            balanceManager: state.deepSeekBalanceManager,
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

/// 通用：菜单栏显示 / 限额刷新间隔 / 用量统计周期默认。
/// 限额口径（已用/剩余）与供应商显隐排序在限额卡片齿轮弹层（TokenUsageLimitsSettingsPopover）。
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

            Section(strings.tokenSettingsDefaultPeriod) {
                Picker(strings.tokenSettingsDefaultPeriod, selection: Binding(
                    get: { preferences.configuration.trendPeriodDefault },
                    set: { period in preferences.update { $0.trendPeriodDefault = period } }
                )) {
                    ForEach(TokenTrendPeriod.allCases) { period in
                        Text(period.label(strings)).tag(period)
                    }
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageDefaultPeriod.rawValue)
            }
        }
        .settingsPageStyle()
    }
}

/// 提供商：15 家凭证状态行；点击行尾「如何配置 ›」/「✓ 已登录 ›」在行下方展开——
/// DeepSeek / Trae CN / OpenCode / 方舟 展开为凭证配置卡，其余提供商展开为配置提示文字。
struct TokenUsageProvidersSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject var manager: TokenUsageManager
    var balanceManager: DeepSeekBalanceManager? = nil
    let strings: Strings
    @State private var expandedProviders: Set<TokenUsageProvider> = []
    /// 钥匙串凭证状态缓存：渲染期不直接读 keychain，onAppear 与凭证保存/清除后刷新一次。
    @State private var opencodeHasKey = false
    @State private var arkHasCredentials = false
    /// DeepSeek 凭证状态（余额管理器 @Published 值缓存，渲染期不依赖 ObservableObject 链）。
    @State private var deepSeekHasKey = false
    /// trae-cn JWT 状态（无 limits fetcher，凭证存在性即配置态）。
    @State private var traeCnHasJWT = false

    /// 展开为凭证配置卡的提供商（其余展开仅显示「如何配置」提示文字）。
    private var credentialProviders: Set<TokenUsageProvider> {
        [.deepSeek, .traeCN, .opencode, .arkCodingPlan]
    }

    var body: some View {
        Form {
            Section(strings.tokenSettingsProvidersSection) {
                ForEach(preferences.configuration.providerOrder) { provider in
                    providerRow(provider)
                }
            }
        }
        .settingsPageStyle()
        .onAppear { reloadCredentialStates() }
    }

    /// 渲染期不直接读钥匙串：onAppear 与凭证保存/清除后刷新一次缓存。
    /// 环境变量（OPENCODE_GO_API_KEY / VOLCENGINE_ACCESS_KEY / ARK_AK）作为钥匙串的补充凭证来源。
    private func reloadCredentialStates() {
        deepSeekHasKey = balanceManager?.apiKeyConfigured ?? false
        let opencodeStore = OpencodeKeychainAPIKeyStore()
        opencodeHasKey = ((try? opencodeStore.readAPIKey())?.isEmpty == false)
            || (ProcessInfo.processInfo.environment["OPENCODE_GO_API_KEY"]?.isEmpty == false)
        let arkStore = ArkKeychainStore()
        arkHasCredentials = ((try? arkStore.readCredentials())?.isValid == true)
            || (ProcessInfo.processInfo.environment["VOLCENGINE_ACCESS_KEY"]?.isEmpty == false)
            || (ProcessInfo.processInfo.environment["ARK_AK"]?.isEmpty == false)
        let traeCnStore = TraeCnKeychainStore()
        traeCnHasJWT = ((try? traeCnStore.readJWT())?.isEmpty == false)
    }

    /// 行尾状态与是否可展开。凭证类提供商恒可展开（含已配置，便于修改/清除凭证）；
    /// 其余提供商仅未配置时给出「如何配置 ›」引导。
    private func providerRowInfo(_ provider: TokenUsageProvider) -> (statusText: String?, showsGuide: Bool) {
        if provider == .deepSeek {
            if deepSeekHasKey {
                return ("✓ " + strings.tokenSettingsLoggedIn, true)
            } else {
                return (
                    String(
                        format: strings.tokenSettingsProviderStatusFormat,
                        strings.tokenSettingsNotConfigured,
                        strings.tokenSettingsHowToConfigure
                    ),
                    true
                )
            }
        } else if provider == .opencode {
            let limits = manager.limits[provider]
            if opencodeHasKey || (limits?.configured == true) {
                if limits?.issue == .reauthRequired {
                    return (strings.tokenStatusReauth, true)
                }
                return ("✓ " + strings.tokenSettingsLoggedIn, true)
            } else {
                return (
                    String(
                        format: strings.tokenSettingsProviderStatusFormat,
                        strings.tokenSettingsNotConfigured,
                        strings.tokenSettingsHowToConfigure
                    ),
                    true
                )
            }
        } else if provider == .arkCodingPlan {
            let limits = manager.limits[provider]
            if arkHasCredentials || (limits?.configured == true) {
                if limits?.issue == .reauthRequired {
                    return (strings.tokenStatusReauth, true)
                }
                return ("✓ " + strings.tokenSettingsLoggedIn, true)
            } else {
                return (
                    String(
                        format: strings.tokenSettingsProviderStatusFormat,
                        strings.tokenSettingsNotConfigured,
                        strings.tokenSettingsHowToConfigure
                    ),
                    true
                )
            }
        } else if provider == .traeCN {
            if traeCnHasJWT {
                return ("✓ " + strings.tokenSettingsLoggedIn, true)
            } else {
                return (
                    String(
                        format: strings.tokenSettingsProviderStatusFormat,
                        strings.tokenSettingsNotConfigured,
                        strings.tokenSettingsHowToConfigure
                    ),
                    true
                )
            }
        } else {
            // 非凭证类提供商：未配置时给「如何配置 ›」展开引导。
            let limits = manager.limits[provider]
            return (
                TokenUsageProviderStatusBuilder.statusText(limits: limits, strings: strings),
                TokenUsageProviderStatusBuilder.showsConfigureGuide(limits)
            )
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: TokenUsageProvider) -> some View {
        let info = providerRowInfo(provider)
        let statusText = info.statusText
        let showsGuide = info.showsGuide
        let isExpanded = expandedProviders.contains(provider)

        VStack(alignment: .leading, spacing: 0) {
            rowButton(provider: provider, statusText: statusText, showsGuide: showsGuide, isExpanded: isExpanded)

            if showsGuide && isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    expandedContent(for: provider)
                }
                .padding(.leading, 24)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageProviderState(provider))
    }

    /// 整行可点击：凭证类提供商与未配置行点击即展开/收起（状态文本与 chevron 用强调色示意可点）。
    @ViewBuilder
    private func rowButton(
        provider: TokenUsageProvider,
        statusText: String?,
        showsGuide: Bool,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(provider.accentColor)
                .frame(width: 8, height: 8)
            Text(provider.displayName)
            Spacer()
            if let statusText {
                if showsGuide {
                    HStack(spacing: 4) {
                        Text(statusText)
                            .foregroundStyle(Color.accentColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                } else {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showsGuide {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toggleExpanded(provider)
                }
            }
        }
    }

    /// 展开内容：凭证类提供商渲染行内凭证配置卡，其余提供商显示「如何配置」提示文字。
    @ViewBuilder
    private func expandedContent(for provider: TokenUsageProvider) -> some View {
        switch provider {
        case .deepSeek:
            if let balanceManager {
                DeepSeekBalanceSettingsCard(
                    preferences: preferences,
                    manager: balanceManager,
                    onCredentialsChanged: reloadCredentialStates,
                    strings: strings
                )
            }
        case .traeCN:
            TraeCnSettingsCard(
                preferences: preferences,
                strings: strings
            )
        case .opencode:
            OpencodeSettingsCard(
                preferences: preferences,
                manager: manager,
                onCredentialsChanged: reloadCredentialStates,
                strings: strings
            )
        case .arkCodingPlan:
            ArkCodingPlanSettingsCard(
                preferences: preferences,
                manager: manager,
                onCredentialsChanged: reloadCredentialStates,
                strings: strings
            )
        default:
            Text(TokenUsageProviderStatusBuilder.configureHint(for: provider, strings: strings))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleExpanded(_ provider: TokenUsageProvider) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
    }
}

/// 行内凭证输入行（API Key 等单字段凭证）：可选标题 + SecureField + 持久状态 + 保存/清除 + 错误反馈 + 说明。
/// OpenCode / DeepSeek 等提供商凭证卡共用，保证交互与视觉一致。
struct TokenCredentialRow: View {
    enum Feedback: Equatable {
        case none
        case error(String)
    }

    /// 小标题（如「API Key」）；nil 不显示。
    var title: String? = nil
    let placeholder: String
    @Binding var text: String
    /// 钥匙串中是否已存凭证（驱动「已保存/未配置密钥」状态与清除按钮）。
    let hasStoredValue: Bool
    let caption: String
    let canSave: Bool
    var feedback: Feedback = .none
    let onSave: () -> Void
    let onClear: () -> Void
    let strings: Strings
    var fieldID: String? = nil
    var saveID: String? = nil
    var clearID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(fieldID ?? "")
            HStack(spacing: 8) {
                if hasStoredValue {
                    Text(strings.deepSeekSettingsKeySaved)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(strings.deepSeekSettingsKeyMissing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(strings.deepSeekSettingsSaveKey) {
                    onSave()
                }
                .disabled(!canSave)
                .accessibilityIdentifier(saveID ?? "")
                if hasStoredValue {
                    Button(strings.deepSeekSettingsClearKey, role: .destructive) {
                        onClear()
                    }
                    .accessibilityIdentifier(clearID ?? "")
                }
            }
            switch feedback {
            case .error(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .none:
                EmptyView()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 告警：会话窗阈值（70/85/90/95 可配）与步速超前开关 + 通知权限申请入口。
struct TokenUsageAlertsSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject private var permissions = Permissions.shared
    let strings: Strings

    var body: some View {
        Form {
            Section(strings.tokenSettingsAlertsSection) {
                Toggle(
                    String(
                        format: strings.tokenSettingsSessionAlertFormat,
                        preferences.configuration.sessionAlertThresholdPercent
                    ),
                    isOn: alertBinding(\.sessionLimitAlertEnabled)
                )
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageSessionAlert.rawValue)

                Picker(strings.tokenSettingsAlertThreshold, selection: Binding(
                    get: { preferences.configuration.sessionAlertThresholdPercent },
                    set: { percent in try? preferences.setSessionAlertThresholdPercent(percent) }
                )) {
                    ForEach(TokenUsageConfiguration.allowedSessionAlertThresholds, id: \.self) { percent in
                        Text(String(format: strings.tokenSettingsAlertThresholdFormat, percent))
                            .tag(percent)
                    }
                }
                .accessibilityIdentifier(SettingsAccessibilityID.tokenUsageAlertThreshold.rawValue)

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

/// DeepSeek 余额配置卡（提供商行内展开）：API Key（钥匙串）/ 低余额通知（开关 + 阈值）/ 刷新间隔。
struct DeepSeekBalanceSettingsCard: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject var manager: DeepSeekBalanceManager
    /// 凭证变更（保存/清除）后通知父级刷新行状态缓存。
    var onCredentialsChanged: () -> Void = {}
    let strings: Strings

    @State private var apiKeyInput = ""
    @State private var saveFailed = false
    @State private var thresholdText = ""
    @State private var thresholdError = false
    @FocusState private var thresholdFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            apiKeyRow
            Divider()
            lowBalanceRow
            Divider()
            refreshRow
        }
        .onAppear {
            thresholdText = Self.formatThreshold(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold)
        }
    }

    // MARK: - API Key

    private var apiKeyRow: some View {
        TokenCredentialRow(
            title: strings.tokenSettingsApiKeyTitle,
            placeholder: strings.deepSeekSettingsApiKeyPlaceholder,
            text: $apiKeyInput,
            hasStoredValue: manager.apiKeyConfigured,
            caption: strings.deepSeekSettingsApiKeyCaption,
            canSave: !DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput).isEmpty,
            feedback: saveFailed ? .error(strings.deepSeekSettingsApiKeyInvalid) : .none,
            onSave: saveKey,
            onClear: clearKey,
            strings: strings,
            fieldID: SettingsAccessibilityID.deepSeekApiKeyField.rawValue,
            saveID: SettingsAccessibilityID.deepSeekSaveKey.rawValue,
            clearID: SettingsAccessibilityID.deepSeekClearKey.rawValue
        )
        .onChange(of: apiKeyInput) { _, _ in
            saveFailed = false
        }
    }

    // MARK: - 低余额通知

    private var lowBalanceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.deepSeekSettingsLowBalanceAlert)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(strings.deepSeekSettingsLowBalanceAlertToggle, isOn: Binding(
                get: { preferences.configuration.deepSeekBalanceSettings.lowBalanceAlertEnabled },
                set: { preferences.setDeepSeekLowBalanceAlertEnabled($0) }
            ))
            .accessibilityIdentifier(SettingsAccessibilityID.deepSeekLowBalanceToggle.rawValue)

            HStack {
                Text(strings.deepSeekSettingsThresholdLabel)
                Spacer()
                TextField("", text: $thresholdText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(SettingsAccessibilityID.deepSeekThresholdField.rawValue)
                    .focused($thresholdFocused)
                    .onSubmit { commitThreshold() }
                    .onChange(of: thresholdFocused) { _, focused in
                        if !focused { commitThreshold() }
                    }
                    .onChange(of: thresholdText) { _, _ in
                        thresholdError = false
                    }
            }
            if thresholdError {
                Text(strings.deepSeekSettingsThresholdInvalid)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(strings.deepSeekSettingsThresholdHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 刷新间隔

    private var refreshRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.deepSeekSettingsRefreshInterval)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(strings.deepSeekSettingsRefreshInterval, selection: Binding(
                get: { preferences.configuration.deepSeekBalanceSettings.refreshMinutes },
                set: { minutes in try? preferences.setDeepSeekRefreshMinutes(minutes) }
            )) {
                ForEach(DeepSeekBalanceSettings.allowedRefreshIntervals, id: \.self) { minutes in
                    Text(String(format: strings.tokenSettingsRefreshMinuteFormat, minutes))
                        .tag(minutes)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier(SettingsAccessibilityID.deepSeekRefreshInterval.rawValue)
        }
    }

    // MARK: - 动作

    private func saveKey() {
        do {
            try manager.saveAPIKey(DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput))
            apiKeyInput = ""
            saveFailed = false
            onCredentialsChanged()
        } catch {
            saveFailed = true
        }
    }

    private func clearKey() {
        try? manager.deleteAPIKey()
        apiKeyInput = ""
        saveFailed = false
        onCredentialsChanged()
    }

    /// 回车或失焦提交；非法输入红字提示并回退显示当前值，不静默丢弃。
    private func commitThreshold() {
        guard let value = DeepSeekSettingsValidation.parseThreshold(thresholdText) else {
            thresholdError = true
            thresholdText = Self.formatThreshold(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold)
            return
        }
        thresholdError = false
        preferences.setDeepSeekThreshold(value)
        thresholdText = Self.formatThreshold(value)
    }

    private static func formatThreshold(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// trae-cn 配置卡（提供商行内展开）：opt-in 开关（默认关，SPEC R1）+ Cloud-IDE-JWT 手动输入（钥匙串）。
struct TraeCnSettingsCard: View {
    @ObservedObject var preferences: TokenUsagePreferences
    let strings: Strings

    @State private var jwtInput = ""
    @State private var saveFailed = false
    @State private var saveSuccess = false
    /// 钥匙串凭证状态缓存（onAppear 与保存/清除后刷新，渲染期不直接读 keychain）。
    @State private var hasStoredKey = false

    private let keychain = TraeCnKeychainStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(strings.tokenSettingsTraeCnSection, isOn: Binding(
                get: { preferences.configuration.traeCnEnabled },
                set: { enabled in preferences.setTraeCnEnabled(enabled) }
            ))
            SecureField(strings.tokenSettingsTraeCnJwtPlaceholder, text: $jwtInput)
                .textFieldStyle(.roundedBorder)
                .onChange(of: jwtInput) { _, _ in
                    saveSuccess = false
                }
            HStack {
                Button(strings.deepSeekSettingsSaveKey) {
                    save()
                }
                .disabled(DeepSeekSettingsValidation.sanitizedAPIKey(jwtInput).isEmpty)
                Button(strings.deepSeekSettingsClearKey) {
                    clearKey()
                }
                .disabled(jwtInput.isEmpty && !hasStoredKey)
            }
            if saveFailed {
                Text(strings.tokenErrorTransient)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if saveSuccess {
                Text(strings.deepSeekSettingsKeySaved)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(strings.tokenSettingsConfigureHintTraeCn)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reloadKeychainState() }
    }

    private func reloadKeychainState() {
        let stored = (try? keychain.readJWT()) ?? ""
        jwtInput = stored
        hasStoredKey = !stored.isEmpty
    }

    private func save() {
        do {
            try keychain.writeJWT(DeepSeekSettingsValidation.sanitizedAPIKey(jwtInput))
            saveFailed = false
            saveSuccess = true
            hasStoredKey = true
        } catch {
            saveFailed = true
            saveSuccess = false
        }
    }

    private func clearKey() {
        try? keychain.deleteJWT()
        jwtInput = ""
        saveFailed = false
        saveSuccess = false
        hasStoredKey = false
    }
}

/// OpenCode Go 配置卡（提供商行内展开）：API Key（钥匙串存储）。
struct OpencodeSettingsCard: View {
    @ObservedObject var preferences: TokenUsagePreferences
    var manager: TokenUsageManager? = nil
    /// 凭证变更（保存/清除）后通知父级刷新行状态缓存。
    var onCredentialsChanged: () -> Void = {}
    let strings: Strings

    @State private var apiKeyInput = ""
    @State private var saveFailed = false
    /// 钥匙串凭证状态缓存（onAppear 与保存/清除后刷新，渲染期不直接读 keychain）。
    @State private var hasStoredKey = false

    private let keychain = OpencodeKeychainAPIKeyStore()

    var body: some View {
        TokenCredentialRow(
            title: strings.tokenSettingsApiKeyTitle,
            placeholder: strings.opencodeSettingsApiKeyPlaceholder,
            text: $apiKeyInput,
            hasStoredValue: hasStoredKey,
            caption: strings.opencodeSettingsApiKeyCaption,
            canSave: !DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput).isEmpty,
            feedback: saveFailed ? .error(strings.tokenErrorTransient) : .none,
            onSave: save,
            onClear: clearKey,
            strings: strings
        )
        .onChange(of: apiKeyInput) { _, _ in
            saveFailed = false
        }
        .onAppear { reloadKeychainState() }
    }

    private func reloadKeychainState() {
        let stored = (try? keychain.readAPIKey()) ?? ""
        hasStoredKey = !stored.isEmpty
    }

    private func save() {
        let cleaned = DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput)
        guard !cleaned.isEmpty else { return }
        do {
            try keychain.writeAPIKey(cleaned)
            apiKeyInput = ""
            saveFailed = false
            hasStoredKey = true
            manager?.refreshNow()
            onCredentialsChanged()
        } catch {
            saveFailed = true
        }
    }

    private func clearKey() {
        try? keychain.deleteAPIKey()
        apiKeyInput = ""
        saveFailed = false
        hasStoredKey = false
        manager?.refreshNow()
        onCredentialsChanged()
    }
}

/// 方舟 Coding Plan 配置卡（提供商行内展开）：AccessKey ID / SecretAccessKey（钥匙串）/ 保存 / 清除。
struct ArkCodingPlanSettingsCard: View {
    @ObservedObject var preferences: TokenUsagePreferences
    var manager: TokenUsageManager? = nil
    /// 凭证变更（保存/清除）后通知父级刷新行状态缓存。
    var onCredentialsChanged: () -> Void = {}
    let strings: Strings

    @State private var akInput = ""
    @State private var skInput = ""
    @State private var saveFailed = false
    @State private var saveSuccess = false
    /// 钥匙串凭证状态缓存（onAppear 与保存/清除后刷新，渲染期不直接读 keychain）。
    @State private var hasStoredCredentials = false

    private let keychain = ArkKeychainStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(strings.arkSettingsAkPlaceholder, text: $akInput)
                .textFieldStyle(.roundedBorder)
                .onChange(of: akInput) { _, _ in
                    saveSuccess = false
                }
            SecureField(strings.arkSettingsSkPlaceholder, text: $skInput)
                .textFieldStyle(.roundedBorder)
                .onChange(of: skInput) { _, _ in
                    saveSuccess = false
                }
            HStack {
                Button(strings.deepSeekSettingsSaveKey) {
                    save()
                }
                .disabled(akInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || skInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(strings.deepSeekSettingsClearKey) {
                    clear()
                }
                .disabled(akInput.isEmpty && skInput.isEmpty && !hasStoredCredentials)
            }
            if saveFailed {
                Text(strings.tokenErrorTransient)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if saveSuccess {
                Text(strings.deepSeekSettingsKeySaved)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text(strings.arkSettingsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { reloadKeychainState() }
    }

    private func reloadKeychainState() {
        if let creds = try? keychain.readCredentials() {
            akInput = creds.accessKeyId
            skInput = creds.secretAccessKey
            hasStoredCredentials = true
        } else {
            akInput = ""
            skInput = ""
            hasStoredCredentials = false
        }
    }

    private func save() {
        let ak = akInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = skInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty, !sk.isEmpty else { return }
        do {
            try keychain.writeCredentials(ArkCredentials(accessKeyId: ak, secretAccessKey: sk))
            saveFailed = false
            saveSuccess = true
            hasStoredCredentials = true
            manager?.refreshNow()
            onCredentialsChanged()
        } catch {
            saveFailed = true
            saveSuccess = false
        }
    }

    private func clear() {
        try? keychain.deleteCredentials()
        akInput = ""
        skInput = ""
        saveFailed = false
        saveSuccess = false
        hasStoredCredentials = false
        manager?.refreshNow()
        onCredentialsChanged()
    }
}


