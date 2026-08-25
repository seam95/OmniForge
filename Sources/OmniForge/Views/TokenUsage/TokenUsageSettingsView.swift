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
                    case .deepSeek:
                        if let balanceManager = state.deepSeekBalanceManager {
                            DeepSeekBalanceSettingsView(
                                preferences: preferences,
                                manager: balanceManager,
                                strings: state.l10n.s
                            )
                        }
                    case .traeCn:
                        TraeCnSettingsView(
                            preferences: preferences,
                            strings: state.l10n.s
                        )
                    case .opencode:
                        OpencodeSettingsView(
                            preferences: preferences,
                            manager: manager,
                            strings: state.l10n.s
                        )
                    case .arkCodingPlan:
                        ArkCodingPlanSettingsView(
                            preferences: preferences,
                            manager: manager,
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

/// 提供商：各家凭证状态与自定义排序；未配置给「如何配置 ›」展开引导。
struct TokenUsageProvidersSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject var manager: TokenUsageManager
    var balanceManager: DeepSeekBalanceManager? = nil
    let strings: Strings
    @State private var expandedProviders: Set<TokenUsageProvider> = []

    var body: some View {
        Form {
            Section(strings.tokenSettingsProvidersSection) {
                ForEach(preferences.configuration.providerOrder) { provider in
                    providerRow(provider)
                }
            }
        }
        .settingsPageStyle()
    }

    private func providerRowInfo(_ provider: TokenUsageProvider) -> (statusText: String?, showsGuide: Bool) {
        if provider == .deepSeek {
            let isConfigured = balanceManager?.apiKeyConfigured ?? false
            if isConfigured {
                return ("✓ " + strings.tokenSettingsLoggedIn, false)
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
            let keyStore = OpencodeKeychainAPIKeyStore()
            let hasKey = ((try? keyStore.readAPIKey())?.isEmpty == false)
                || (ProcessInfo.processInfo.environment["OPENCODE_GO_API_KEY"]?.isEmpty == false)
            let limits = manager.limits[provider]
            if hasKey || (limits?.configured == true) {
                if limits?.issue == .reauthRequired {
                    return (strings.tokenStatusReauth, false)
                }
                return ("✓ " + strings.tokenSettingsLoggedIn, false)
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
            let keyStore = ArkKeychainStore()
            let hasCreds = ((try? keyStore.readCredentials())?.isValid == true)
                || (ProcessInfo.processInfo.environment["VOLCENGINE_ACCESS_KEY"]?.isEmpty == false)
                || (ProcessInfo.processInfo.environment["ARK_AK"]?.isEmpty == false)
            let limits = manager.limits[provider]
            if hasCreds || (limits?.configured == true) {
                if limits?.issue == .reauthRequired {
                    return (strings.tokenStatusReauth, false)
                }
                return ("✓ " + strings.tokenSettingsLoggedIn, false)
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

/// DeepSeek 余额设置：API Key（钥匙串）/ 低余额通知（开关 + 阈值）/ 刷新间隔。
struct DeepSeekBalanceSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    @ObservedObject var manager: DeepSeekBalanceManager
    let strings: Strings

    @State private var apiKeyInput = ""
    @State private var saveFailed = false
    @State private var thresholdText = ""

    var body: some View {
        Form {
            apiKeySection
            lowBalanceSection
            refreshSection
        }
        .settingsPageStyle()
        .onAppear { thresholdText = Self.formatThreshold(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold) }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        Section {
            SecureField(strings.deepSeekSettingsApiKeyPlaceholder, text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(SettingsAccessibilityID.deepSeekApiKeyField.rawValue)
            HStack(spacing: 8) {
                if manager.apiKeyConfigured {
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
                    saveKey()
                }
                .disabled(DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput).isEmpty)
                .accessibilityIdentifier(SettingsAccessibilityID.deepSeekSaveKey.rawValue)
                if manager.apiKeyConfigured {
                    Button(strings.deepSeekSettingsClearKey, role: .destructive) {
                        clearKey()
                    }
                    .accessibilityIdentifier(SettingsAccessibilityID.deepSeekClearKey.rawValue)
                }
            }
            if saveFailed {
                Text(strings.deepSeekSettingsApiKeyInvalid)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(strings.deepSeekSettingsApiKeySection)
        } footer: {
            Text(strings.deepSeekSettingsApiKeyCaption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 低余额通知

    private var lowBalanceSection: some View {
        Section {
            Toggle(strings.deepSeekSettingsLowBalanceAlert, isOn: Binding(
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
                    .onSubmit { commitThreshold() }
            }
        } header: {
            Text(strings.deepSeekSettingsLowBalanceAlert)
        } footer: {
            Text(strings.deepSeekSettingsThresholdHint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 刷新间隔

    private var refreshSection: some View {
        Section(strings.deepSeekSettingsRefreshInterval) {
            Picker(strings.deepSeekSettingsRefreshInterval, selection: Binding(
                get: { preferences.configuration.deepSeekBalanceSettings.refreshMinutes },
                set: { minutes in try? preferences.setDeepSeekRefreshMinutes(minutes) }
            )) {
                ForEach(DeepSeekBalanceSettings.allowedRefreshIntervals, id: \.self) { minutes in
                    Text(String(format: strings.tokenSettingsRefreshMinuteFormat, minutes))
                        .tag(minutes)
                }
            }
            .accessibilityIdentifier(SettingsAccessibilityID.deepSeekRefreshInterval.rawValue)
        }
    }

    // MARK: - 动作

    private func saveKey() {
        do {
            try manager.saveAPIKey(DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput))
            apiKeyInput = ""
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    private func clearKey() {
        try? manager.deleteAPIKey()
        apiKeyInput = ""
        saveFailed = false
    }

    private func commitThreshold() {
        guard let value = DeepSeekSettingsValidation.parseThreshold(thresholdText) else {
            thresholdText = Self.formatThreshold(preferences.configuration.deepSeekBalanceSettings.lowBalanceThreshold)
            return
        }
        preferences.setDeepSeekThreshold(value)
        thresholdText = Self.formatThreshold(value)
    }

    private static func formatThreshold(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// trae-cn 采集设置：opt-in 开关（默认关，SPEC R1）+ Cloud-IDE-JWT 手动输入（钥匙串）。
struct TraeCnSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    let strings: Strings

    @State private var jwtInput = ""
    @State private var saveFailed = false

    private let keychain = TraeCnKeychainStore()

    var body: some View {
        Form {
            Section {
                Toggle(strings.tokenSettingsTraeCnSection, isOn: Binding(
                    get: { preferences.configuration.traeCnEnabled },
                    set: { enabled in preferences.setTraeCnEnabled(enabled) }
                ))
                SecureField(strings.tokenSettingsTraeCnJwtPlaceholder, text: $jwtInput)
                    .textFieldStyle(.roundedBorder)
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
                        .foregroundStyle(Theme.Stats.up)
                }
            } header: {
                Text(strings.tokenSettingsTraeCnSection)
            } footer: {
                Text(strings.tokenSettingsConfigureHintTraeCn)
            }
        }
        .settingsPageStyle()
        .onAppear {
            jwtInput = (try? keychain.readJWT()) ?? ""
        }
    }

    private var hasStoredKey: Bool {
        ((try? keychain.readJWT()) ?? nil) != nil
    }

    private func save() {
        do {
            try keychain.writeJWT(DeepSeekSettingsValidation.sanitizedAPIKey(jwtInput))
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    private func clearKey() {
        try? keychain.deleteJWT()
        jwtInput = ""
        saveFailed = false
    }
}

/// OpenCode Go 设置：API Key（钥匙串存储）。
struct OpencodeSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    var manager: TokenUsageManager? = nil
    let strings: Strings

    @State private var apiKeyInput = ""
    @State private var saveFailed = false
    @State private var saveSuccess = false

    private let keychain = OpencodeKeychainAPIKeyStore()

    var body: some View {
        Form {
            Section {
                SecureField(strings.opencodeSettingsApiKeyPlaceholder, text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(strings.deepSeekSettingsSaveKey) {
                        save()
                    }
                    .disabled(DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput).isEmpty)
                    Button(strings.deepSeekSettingsClearKey) {
                        clearKey()
                    }
                    .disabled(apiKeyInput.isEmpty && !hasStoredKey)
                }
                if saveFailed {
                    Text(strings.tokenErrorTransient)
                        .foregroundStyle(Theme.Stats.up)
                } else if saveSuccess {
                    Text(strings.deepSeekSettingsKeySaved)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } header: {
                Text(strings.tokenSettingsOpencodeSection)
            } footer: {
                Text(strings.opencodeSettingsApiKeyCaption)
            }
        }
        .settingsPageStyle()
        .onAppear {
            apiKeyInput = (try? keychain.readAPIKey()) ?? ""
        }
    }

    private var hasStoredKey: Bool {
        ((try? keychain.readAPIKey()) ?? nil) != nil
    }

    private func save() {
        let cleaned = DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput)
        guard !cleaned.isEmpty else { return }
        do {
            try keychain.writeAPIKey(cleaned)
            saveFailed = false
            saveSuccess = true
            manager?.refreshNow()
        } catch {
            saveFailed = true
            saveSuccess = false
        }
    }

    private func clearKey() {
        try? keychain.deleteAPIKey()
        apiKeyInput = ""
        saveFailed = false
        saveSuccess = false
        manager?.refreshNow()
    }
}

/// 方舟 Coding Plan 设置：AccessKey ID / SecretAccessKey（钥匙串）/ 保存 / 清除。
struct ArkCodingPlanSettingsView: View {
    @ObservedObject var preferences: TokenUsagePreferences
    var manager: TokenUsageManager? = nil
    let strings: Strings

    @State private var akInput = ""
    @State private var skInput = ""
    @State private var saveFailed = false
    @State private var saveSuccess = false

    private let keychain = ArkKeychainStore()

    var body: some View {
        Form {
            Section {
                TextField(strings.arkSettingsAkPlaceholder, text: $akInput)
                    .textFieldStyle(.roundedBorder)
                SecureField(strings.arkSettingsSkPlaceholder, text: $skInput)
                    .textFieldStyle(.roundedBorder)
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
                        .foregroundStyle(Theme.Stats.up)
                } else if saveSuccess {
                    Text(strings.deepSeekSettingsKeySaved)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } header: {
                Text(strings.tokenSettingsArkSection)
            } footer: {
                Text(strings.arkSettingsCaption)
            }
        }
        .settingsPageStyle()
        .onAppear {
            if let creds = try? keychain.readCredentials() {
                akInput = creds.accessKeyId
                skInput = creds.secretAccessKey
            }
        }
    }

    private var hasStoredCredentials: Bool {
        ((try? keychain.readCredentials()) ?? nil) != nil
    }

    private func save() {
        let ak = akInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = skInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty, !sk.isEmpty else { return }
        do {
            try keychain.writeCredentials(ArkCredentials(accessKeyId: ak, secretAccessKey: sk))
            saveFailed = false
            saveSuccess = true
            manager?.refreshNow()
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
        manager?.refreshNow()
    }
}


