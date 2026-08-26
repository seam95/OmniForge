import SwiftUI

/// 供应商档案表单（新增 / 编辑，SPEC 2.9）：
/// 名称、Base URL、凭证、可选模型（Claude Code 另含小模型）；可从内置 preset 一键带入连接参数。
/// 新增模式带「预设」下拉（选择后带入 base URL / 默认模型）；编辑模式隐藏预设。
struct ProfileEditorView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    let tool: ProviderTool
    /// nil = 新增；非 nil = 编辑既有档案。
    var profile: ProviderProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var token = ""
    @State private var model = ""
    @State private var smallModel = ""
    @State private var presetID: String?
    @State private var errorMessage: String?

    private var isEditing: Bool { profile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            if !isEditing {
                Picker(strings.providerPresetLabel, selection: $presetID) {
                    Text(strings.providerPresetNone).tag(String?.none)
                    ForEach(ProviderPresetCatalog.builtins) { preset in
                        Text(preset.displayName).tag(String?.some(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
                .onChange(of: presetID) { _, newValue in
                    applyPreset(newValue)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField(strings.providerNameLabel, text: $name)
                TextField(strings.providerBaseURLLabel, text: $baseURL)
                    .textContentType(.URL)
                SecureField(strings.providerTokenLabel, text: $token)
                    .textContentType(.password)
                TextField(strings.providerModelLabel, text: $model)
                if tool == .claudeCode {
                    TextField(strings.providerSmallFastModelLabel, text: $smallModel)
                }
                Text(strings.providerModelHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(strings.providerFormCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(strings.providerFormSave, action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear(perform: loadInitialValues)
    }

    private var title: String {
        let toolName = tool.displayName(in: strings)
        return isEditing
            ? String(format: strings.providerFormTitleEditFormat, toolName)
            : String(format: strings.providerFormTitleNewFormat, toolName)
    }

    private var canSave: Bool {
        let name = trimmed(name)
        let baseURL = trimmed(baseURL)
        let token = trimmed(token)
        return !name.isEmpty && !baseURL.isEmpty && !token.isEmpty
    }

    private func loadInitialValues() {
        guard let profile else {
            // 新增：默认选第一家可用 preset 带入（GLM），可手动切换
            if let first = ProviderPresetCatalog.builtins.first {
                presetID = first.id
                applyPreset(first.id)
            }
            return
        }
        name = profile.name
        baseURL = profile.baseURL
        token = profile.token
        model = profile.modelOverride ?? ""
        smallModel = profile.smallFastModelOverride ?? ""
    }

    /// 从 preset 带入连接参数（仅新增模式；编辑模式下 preset 下拉隐藏）。
    private func applyPreset(_ id: String?) {
        guard let id, let preset = ProviderPresetCatalog.preset(id: id) else { return }
        switch tool {
        case .claudeCode:
            if let connection = preset.claudeCode {
                baseURL = connection.baseURL
                model = connection.defaultModel
                smallModel = connection.defaultSmallFastModel ?? ""
            }
        case .codex:
            if let connection = preset.codex {
                baseURL = connection.baseURL
                model = connection.defaultModel
            }
        }
    }

    private func save() {
        let profileName = trimmed(name)
        let profile = ProviderProfile(
            id: self.profile?.id ?? ProviderProfile.slugify(profileName),
            name: profileName,
            tool: tool,
            baseURL: trimmed(baseURL),
            token: trimmed(token),
            modelOverride: emptyToNil(trimmed(model)),
            smallFastModelOverride: tool == .claudeCode ? emptyToNil(trimmed(smallModel)) : nil,
            // 收编外部文件时保留原来源标记；本 App 新建一律打 omniforge
            managedBy: self.profile?.managedBy ?? ProviderProfile.managedByMarker
        )
        do {
            try manager.upsertProfile(profile)
            dismiss()
        } catch ProviderProfileStoreError.nameConflict {
            errorMessage = strings.providerFormNameConflict
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
