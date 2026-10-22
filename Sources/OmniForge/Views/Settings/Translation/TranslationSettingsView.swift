import KeyboardShortcuts
import SwiftUI

// MARK: - 翻译设置页

/// 翻译设置页：语言默认值、默认引擎、AI 接口（Base URL / 模型 / 可选 API Key）、
/// 固定短文本连接测试与快捷键录制。
///
/// 普通偏好与浮窗、管理页共享同一个 `TranslationPreferences` 实例；API Key 走本功能
/// 独立的 Keychain 条目，不进入 UserDefaults，界面不回显已存 Key。
struct TranslationSettingsView: View {
    @ObservedObject var preferences: TranslationPreferences
    @ObservedObject var manager: TranslationManager
    let keychain: TranslationAPIKeyStoring
    let strings: Strings
    /// 录键冲突检测与注册；nil 时降级为直接写偏好（无冲突检测）。
    var hotkeyManager: TranslationHotkeyManager?
    /// 连接测试注入点：nil 时使用内置 AITranslationService；由 Lead 接线可替换。
    var testConnection: (() async throws -> String)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var baseURLText = ""
    @State private var modelText = ""
    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var keySaveFailed = false
    @State private var isTestingConnection = false
    @State private var testResult: ConnectionTestResult?
    @State private var hotkeyError: String?
    @FocusState private var baseURLFocused: Bool
    @FocusState private var modelFocused: Bool
    @FocusState private var apiKeyFocused: Bool

    /// 连接测试结果（行内反馈：成功绿 / 失败红）。
    private struct ConnectionTestResult {
        let text: String
        let isFailure: Bool
    }

    private var l10n: L10n { L10n(userDefaults: .standard) }

    init(
        preferences: TranslationPreferences,
        manager: TranslationManager,
        keychain: TranslationAPIKeyStoring,
        strings: Strings,
        hotkeyManager: TranslationHotkeyManager? = nil,
        testConnection: (() async throws -> String)? = nil
    ) {
        self.preferences = preferences
        self.manager = manager
        self.keychain = keychain
        self.strings = strings
        self.hotkeyManager = hotkeyManager
        self.testConnection = testConnection
    }

    var body: some View {
        Form {
            engineSection
            modelSection
            languageSection
            hotkeySection
        }
        .settingsPageStyle()
        .onAppear {
            reloadKeychainState()
            baseURLText = preferences.baseURL
            modelText = preferences.model
        }
    }

    // MARK: - 引擎

    private var engineSection: some View {
        Section(strings.translationSettingsEngineSection) {
            Picker(strings.translationDefaultEngine, selection: engineBinding) {
                Text(
                    TranslationPresentation.engineLabel(
                        .system,
                        strings: strings,
                        systemUnavailable: !TranslationPreferences.isSystemTranslationSupported
                    )
                )
                .tag(TranslationEngineID.system)
                Text(strings.translationEngineAI)
                    .tag(TranslationEngineID.ai)
            }

            if preferences.engine == .system {
                Text(strings.translationSettingsEngineSystemHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(strings.translationSettingsEngineAIHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // macOS 14 上存储系统引擎会在本次运行降级为 AI：明确提示，不静默切换。
            if preferences.isSystemPreferenceDowngraded() {
                Text(strings.translationEngineDowngradedHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                if !preferences.isAIConfigured {
                    Text(strings.translationAIConfigurationHint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var engineBinding: Binding<TranslationEngineID> {
        Binding(
            get: { preferences.engine },
            set: { manager.selectEngine($0) }
        )
    }

    // MARK: - AI 接口

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.translationSettingsBaseURL)
                // grouped Form 会把 TextField 首参提升为行 label，须置空并走 prompt，
                // 否则占位文案泄漏到左列、与输入框内实际值重复显示。
                TextField(
                    "",
                    text: $baseURLText,
                    prompt: Text(strings.translationSettingsBaseURLPlaceholder)
                )
                .textFieldStyle(.roundedBorder)
                .focused($baseURLFocused)
                .onSubmit { commitBaseURL() }
                .onChange(of: baseURLFocused) { _, focused in
                    if !focused { commitBaseURL() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(strings.translationSettingsModel)
                TextField(
                    "",
                    text: $modelText,
                    prompt: Text(strings.translationSettingsModelPlaceholder)
                )
                .textFieldStyle(.roundedBorder)
                .focused($modelFocused)
                .onSubmit { commitModel() }
                .onChange(of: modelFocused) { _, focused in
                    if !focused { commitModel() }
                }
            }

            apiKeyRow
            connectionTestRow
        } header: {
            HStack(spacing: 5) {
                Text(strings.translationSettingsModelSection)
                InfoHintButton(text: strings.translationSettingsPrivacyHint)
            }
        }
    }

    /// API Key 行：Key 为可选；已存 Key 只显示状态，不回显内容。
    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.translationSettingsAPIKey)
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField(
                "",
                text: $apiKeyInput,
                prompt: Text(
                    hasStoredKey
                        ? strings.translationSettingsKeySavedPlaceholder
                        : strings.translationSettingsAPIKeyPlaceholder
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($apiKeyFocused)
            .onChange(of: apiKeyInput) { _, _ in
                keySaveFailed = false
            }

            HStack(spacing: 8) {
                Text(hasStoredKey ? strings.translationSettingsKeySaved : strings.translationSettingsKeyMissing)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(strings.translationSettingsSave) {
                    saveKey()
                }
                .disabled(cleanedAPIKey.isEmpty)

                if hasStoredKey {
                    Button(strings.translationSettingsClear, role: .destructive) {
                        clearKey()
                    }
                }
            }

            if keySaveFailed {
                Text(strings.translationSettingsKeySaveFailed)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(strings.translationSettingsPrivacyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 连接测试行：发送固定短文本，不发送当前会话原文；未保存的 Key 优先用于本次测试。
    private var connectionTestRow: some View {
        HStack(spacing: 10) {
            Button(
                isTestingConnection
                    ? strings.translationSettingsTesting
                    : strings.translationSettingsTestConnection
            ) {
                runConnectionTest()
            }
            .disabled(isTestingConnection)

            if let testResult {
                Text(testResult.text)
                    .font(.caption)
                    .foregroundStyle(testResult.isFailure ? Color.red : Color.green)
            }

            Spacer()
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section(strings.translationSettingsLanguageSection) {
            Picker(strings.translationSettingsSourceLanguage, selection: sourceBinding) {
                Text(strings.translationLanguageAuto)
                    .tag(Optional<String>.none)
                ForEach(TranslationLanguage.selectableLanguageCodes, id: \.self) { code in
                    Text(TranslationPresentation.languageName(for: code, strings: strings))
                        .tag(Optional(code))
                }
            }

            Picker(strings.translationSettingsTargetLanguage, selection: targetBinding) {
                Text(strings.translationTargetAuto)
                    .tag(TranslationTarget.automaticStorageValue)
                ForEach(TranslationLanguage.aiTargetLanguageCodes, id: \.self) { code in
                    Text(TranslationPresentation.languageName(for: code, strings: strings))
                        .tag(code)
                }
            }
        }
    }

    private var sourceBinding: Binding<String?> {
        Binding(
            get: { preferences.sourceLanguage },
            set: { manager.selectSourceLanguage($0) }
        )
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { preferences.target.storageValue },
            set: { manager.selectTarget(TranslationTarget(storageValue: $0)) }
        )
    }

    // MARK: - 快捷键

    private var hotkeySection: some View {
        Section(strings.translationSettingsHotkeySection) {
            HStack {
                Text(strings.translationHotkeyTitle)
                Spacer()
                HotkeyRecorderView(
                    displayText: preferences.hotkey?.displayString ?? strings.translationHotkeyUnset,
                    onShortcutChanged: { shortcut in
                        applyHotkey(shortcut)
                    },
                    l10n: l10n
                )
                if preferences.hotkey != nil {
                    Button(strings.translationHotkeyDisable) {
                        disableHotkey()
                    }
                }
            }

            if let hotkeyError {
                Text(hotkeyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// 显式禁用快捷键：保留翻译功能，只关闭全局快捷键；录键可重新启用。
    private func disableHotkey() {
        hotkeyError = nil
        do {
            if let hotkeyManager {
                try hotkeyManager.setHotkey(nil)
            } else {
                preferences.setHotkey(nil)
            }
        } catch {
            hotkeyError = TranslationPresentation.hotkeyErrorText(for: error, strings: strings)
        }
    }

    /// 录键回调：冲突时不写偏好、不替换当前绑定，并展示被占用的键位。
    private func applyHotkey(_ shortcut: KeyboardShortcuts.Shortcut?) {
        hotkeyError = nil
        guard let definition = HotkeyDefinition(shortcut: shortcut) else { return }
        do {
            if let hotkeyManager {
                try hotkeyManager.setHotkey(definition)
            } else {
                preferences.setHotkey(definition)
            }
        } catch {
            hotkeyError = TranslationPresentation.hotkeyErrorText(for: error, strings: strings)
        }
    }

    // MARK: - Keychain

    private func reloadKeychainState() {
        // 读取失败按「未配置」展示，不阻塞设置页；真正的读取错误由翻译失败路径提示。
        hasStoredKey = (try? keychain.readAPIKey()) != nil
    }

    /// 已输入且未保存的 Key 优先用于当次连接测试；否则读钥匙串。
    private var enteredOrStoredKey: String? {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return (try? keychain.readAPIKey()) ?? nil
    }

    private var cleanedAPIKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveKey() {
        let cleaned = cleanedAPIKey
        guard !cleaned.isEmpty else { return }
        do {
            try keychain.writeAPIKey(cleaned)
            // 保存后清空输入：界面不回显已存 Key，只保留「密钥已保存」状态。
            apiKeyInput = ""
            apiKeyFocused = false
            hasStoredKey = true
            keySaveFailed = false
        } catch {
            keySaveFailed = true
        }
    }

    private func clearKey() {
        do {
            try keychain.deleteAPIKey()
            apiKeyInput = ""
            hasStoredKey = false
            keySaveFailed = false
        } catch {
            keySaveFailed = true
        }
    }

    // MARK: - 连接测试

    private func runConnectionTest() {
        guard !isTestingConnection else { return }
        commitBaseURL()
        commitModel()
        let apiKey = enteredOrStoredKey
        isTestingConnection = true
        testResult = nil

        Task { @MainActor in
            defer { isTestingConnection = false }
            do {
                if let testConnection {
                    _ = try await testConnection()
                } else {
                    // 固定短文本测试：不发送当前会话原文。
                    let configuration = preferences.aiConfiguration(apiKey: apiKey)
                    _ = try await AITranslationService(configuration: configuration).testConnection()
                }
                testResult = ConnectionTestResult(
                    text: strings.translationSettingsTestSuccess,
                    isFailure: false
                )
            } catch let error as TranslationError {
                testResult = ConnectionTestResult(
                    text: TranslationPresentation.errorMessage(error, strings: strings),
                    isFailure: true
                )
            } catch {
                testResult = ConnectionTestResult(
                    text: strings.translationSettingsTestFailed,
                    isFailure: true
                )
            }
        }
    }

    // MARK: - 偏好提交

    /// Base URL / 模型按失焦或回车提交：避免逐字符写 UserDefaults 与半截地址。
    private func commitBaseURL() {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURLText = trimmed
        preferences.baseURL = trimmed
    }

    private func commitModel() {
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        modelText = trimmed
        preferences.model = trimmed
    }
}
