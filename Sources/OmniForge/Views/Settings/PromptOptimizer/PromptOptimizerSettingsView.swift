import SwiftUI

/// 提示词优化设置页（第 14 个 tab）：模型配置（baseURL / 模型名 / API Key→Keychain）、
/// 行为（自动替换选中文本）、快捷键录键。API Key 凭证行复用 TokenCredentialRow。
struct PromptOptimizerSettingsView: View {
    let state: AppState

    @State private var apiKeyInput = ""
    @State private var hasStoredKey = false
    @State private var saveFailed = false

    @State private var baseURLText = ""
    @State private var modelText = ""
    @FocusState private var baseURLFocused: Bool
    @FocusState private var modelFocused: Bool

    private let keychain = PromptOptimizerKeychainAPIKeyStore()
    private var strings: Strings { state.l10n.s }

    var body: some View {
        Form {
            modelSection
            behaviorSection
            hotkeySection
        }
        .settingsPageStyle()
        .onAppear {
            reloadKeychainState()
            baseURLText = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptOptimizerBaseURL) ?? ""
            modelText = UserDefaults.standard.string(forKey: UserDefaultsKeys.promptOptimizerModel) ?? ""
        }
    }

    // MARK: - 模型配置

    private var modelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.promptOptimizerBaseURL)
                TextField("https://api.deepseek.com/v1", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .focused($baseURLFocused)
                    .onSubmit { commitBaseURL() }
                    .onChange(of: baseURLFocused) { _, focused in
                        if !focused { commitBaseURL() }
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.promptOptimizerModel)
                TextField("deepseek-chat", text: $modelText)
                    .textFieldStyle(.roundedBorder)
                    .focused($modelFocused)
                    .onSubmit { commitModel() }
                    .onChange(of: modelFocused) { _, focused in
                        if !focused { commitModel() }
                    }
            }
            TokenCredentialRow(
                title: strings.promptOptimizerAPIKey,
                placeholder: strings.promptOptimizerAPIKeyPlaceholder,
                text: $apiKeyInput,
                hasStoredValue: hasStoredKey,
                caption: strings.promptOptimizerPrivacyHint,
                canSave: !DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput).isEmpty,
                feedback: saveFailed ? .error(strings.promptOptimizerErrorGeneric) : .none,
                onSave: save,
                onClear: clearKey,
                strings: strings
            )
            .onChange(of: apiKeyInput) { _, _ in
                saveFailed = false
            }
        } header: {
            HStack(spacing: 5) {
                Text(strings.promptOptimizerModelSection)
                InfoHintButton(text: strings.promptOptimizerPrivacyHint)
            }
        }
    }

    // MARK: - 行为

    private var behaviorSection: some View {
        Section(strings.promptOptimizerBehaviorSection) {
            Toggle(isOn: Binding(
                get: {
                    UserDefaults.standard.object(forKey: UserDefaultsKeys.promptOptimizerAutoReplace) != nil
                        ? UserDefaults.standard.bool(forKey: UserDefaultsKeys.promptOptimizerAutoReplace)
                        : false
                },
                set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.promptOptimizerAutoReplace) }
            )) {
                InfoHintLabel(strings.promptOptimizerAutoReplace, hint: strings.promptOptimizerAutoReplaceHint)
            }
        }
    }

    // MARK: - 快捷键

    private var hotkeySection: some View {
        Section(strings.promptOptimizerHotkeySection) {
            if let manager = FeatureRuntime.shared.manager(for: .promptOptimizer, as: PromptOptimizerManager.self) {
                HStack {
                    Text(strings.promptOptimizerHotkey)
                    Spacer()
                    HotkeyRecorderView(
                        displayText: manager.hotkey.displayString,
                        onShortcutChanged: { shortcut in
                            manager.handleRecorderChange(shortcut)
                        },
                        l10n: state.l10n
                    )
                }
            }
        }
    }

    // MARK: - 私有

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
        } catch {
            saveFailed = true
        }
    }

    private func clearKey() {
        try? keychain.deleteAPIKey()
        apiKeyInput = ""
        saveFailed = false
        hasStoredKey = false
    }

    private func commitBaseURL() {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURLText = trimmed
        UserDefaults.standard.set(trimmed, forKey: UserDefaultsKeys.promptOptimizerBaseURL)
    }

    private func commitModel() {
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        modelText = trimmed
        UserDefaults.standard.set(trimmed, forKey: UserDefaultsKeys.promptOptimizerModel)
    }
}
