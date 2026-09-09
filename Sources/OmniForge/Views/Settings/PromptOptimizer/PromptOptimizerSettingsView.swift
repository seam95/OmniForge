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

    /// 连接测试状态：进行中禁用按钮，结果以行内文本反馈。
    @State private var isTestingConnection = false
    @State private var testResult: ConnectionTestResult?

    /// 连接测试结果（行内反馈：成功绿 / 失败红）。
    private struct ConnectionTestResult {
        let text: String
        let isFailure: Bool
    }

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
                // grouped Form 会把 TextField 首参提升为行 label，须置空并走 prompt，
                // 否则 placeholder 泄漏到左列、与输入框内实际值重复显示。
                TextField("", text: $baseURLText, prompt: Text("https://api.deepseek.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .focused($baseURLFocused)
                    .onSubmit { commitBaseURL() }
                    .onChange(of: baseURLFocused) { _, focused in
                        if !focused { commitBaseURL() }
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.promptOptimizerModel)
                TextField("", text: $modelText, prompt: Text("deepseek-chat"))
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
            connectionTestRow
        } header: {
            HStack(spacing: 5) {
                Text(strings.promptOptimizerModelSection)
                InfoHintButton(text: strings.promptOptimizerPrivacyHint)
            }
        }
    }

    // MARK: - 连接测试

    /// 连通性测试行：发送「你好」验证整条链路；caption 标注当前完整请求端点。
    private var connectionTestRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(
                    isTestingConnection
                        ? strings.promptOptimizerTesting
                        : strings.promptOptimizerTestConnection
                ) {
                    runConnectionTest()
                }
                .disabled(isTestingConnection || endpointDisplay == nil)
                if let result = testResult {
                    Text(result.text)
                        .font(.caption)
                        .foregroundStyle(result.isFailure ? Color.red : Color.green)
                }
                Spacer()
            }
            if let endpoint = endpointDisplay {
                Text(String(format: strings.promptOptimizerEndpointFormat, endpoint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 当前输入 baseURL 规范化后的完整端点（含 `/chat/completions`）；baseURL 为空 → nil。
    private var endpointDisplay: String? {
        PromptOptimizerService.endpointURL(forBaseURL: baseURLText)?.absoluteString
    }

    private func runConnectionTest() {
        guard !isTestingConnection else { return }
        commitBaseURL()
        commitModel()
        // 输入框有未保存的 key 时优先用它，方便「先填再测」；否则读钥匙串已存值。
        let entered = DeepSeekSettingsValidation.sanitizedAPIKey(apiKeyInput)
        let apiKey = !entered.isEmpty ? entered : ((try? keychain.readAPIKey()) ?? "")
        guard !apiKey.isEmpty else {
            testResult = ConnectionTestResult(text: strings.promptOptimizerTestNoKey, isFailure: true)
            return
        }
        let service = PromptOptimizerService(baseURL: baseURLText, model: modelText, apiKey: apiKey)
        isTestingConnection = true
        testResult = nil
        Task {
            defer { isTestingConnection = false }
            do {
                _ = try await service.testConnection()
                testResult = ConnectionTestResult(text: strings.promptOptimizerTestSuccess, isFailure: false)
            } catch let error as PromptOptimizerErrorKind {
                testResult = ConnectionTestResult(text: testFailureText(for: error), isFailure: true)
            } catch {
                testResult = ConnectionTestResult(text: strings.promptOptimizerTestFailed, isFailure: true)
            }
        }
    }

    private func testFailureText(for kind: PromptOptimizerErrorKind) -> String {
        switch kind {
        case .network: return strings.promptOptimizerErrorNetwork
        case .timeout: return strings.promptOptimizerErrorTimeout
        case .unauthorized: return strings.promptOptimizerErrorUnauthorized
        default: return strings.promptOptimizerTestFailed
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
            // 保存后保留输入（SecureField 掩码显示），清空会让用户误以为没有输入成功。
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
