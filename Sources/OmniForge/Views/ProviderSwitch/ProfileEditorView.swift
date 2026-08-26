import SwiftUI

/// 供应商档案表单（新增 / 编辑，SPEC 2.9）：
/// 名称、Base URL、凭证、可选模型。Claude Code 另展示角色模型映射（对齐 ccswitch：Sonnet / Opus /
/// Fable / Haiku / Subagent 及其显示名）；Codex 保持单模型字段。可从内置 preset 一键带入连接参数。
/// 新增模式带「预设」下拉（选择后带入 base URL / 默认模型 / 映射 / 额外 env）；编辑模式隐藏预设。
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
    @State private var sonnet = ""
    @State private var sonnetName = ""
    @State private var opus = ""
    @State private var opusName = ""
    @State private var fable = ""
    @State private var fableName = ""
    @State private var haiku = ""
    @State private var haikuName = ""
    @State private var subagent = ""
    @State private var extraEnv: [String: String] = [:]
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
                    modelMappingFields
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

    /// Claude Code 角色模型映射字段组（对齐 ccswitch）。
    @ViewBuilder
    private var modelMappingFields: some View {
        Divider()
        Text(strings.providerModelMappingLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        TextField(strings.providerSonnetModelLabel, text: $sonnet)
        TextField(strings.providerSonnetNameLabel, text: $sonnetName)
        TextField(strings.providerOpusModelLabel, text: $opus)
        TextField(strings.providerOpusNameLabel, text: $opusName)
        TextField(strings.providerFableModelLabel, text: $fable)
        TextField(strings.providerFableNameLabel, text: $fableName)
        TextField(strings.providerHaikuModelLabel, text: $haiku)
        TextField(strings.providerHaikuNameLabel, text: $haikuName)
        TextField(strings.providerSubagentModelLabel, text: $subagent)
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
        sonnet = profile.modelMapping?.sonnet ?? ""
        sonnetName = profile.modelMapping?.sonnetName ?? ""
        opus = profile.modelMapping?.opus ?? ""
        opusName = profile.modelMapping?.opusName ?? ""
        fable = profile.modelMapping?.fable ?? ""
        fableName = profile.modelMapping?.fableName ?? ""
        haiku = profile.modelMapping?.haiku ?? ""
        haikuName = profile.modelMapping?.haikuName ?? ""
        subagent = profile.modelMapping?.subagent ?? ""
        extraEnv = profile.extraEnv
    }

    /// 从 preset 带入连接参数（仅新增模式；编辑模式下 preset 下拉隐藏）。
    private func applyPreset(_ id: String?) {
        guard let id, let preset = ProviderPresetCatalog.preset(id: id) else { return }
        switch tool {
        case .claudeCode:
            if let connection = preset.claudeCode {
                baseURL = connection.baseURL
                model = connection.defaultModel
                sonnet = connection.modelMapping?.sonnet ?? ""
                sonnetName = connection.modelMapping?.sonnetName ?? ""
                opus = connection.modelMapping?.opus ?? ""
                opusName = connection.modelMapping?.opusName ?? ""
                fable = connection.modelMapping?.fable ?? ""
                fableName = connection.modelMapping?.fableName ?? ""
                haiku = connection.modelMapping?.haiku ?? ""
                haikuName = connection.modelMapping?.haikuName ?? ""
                subagent = connection.modelMapping?.subagent ?? ""
                extraEnv = connection.extraEnv
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
            modelMapping: tool == .claudeCode ? makeMapping() : nil,
            extraEnv: tool == .claudeCode ? extraEnv : [:],
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

    /// 汇总角色映射；全部为空 → nil（不写映射字段）。
    private func makeMapping() -> ProviderModelMapping? {
        let mapping = ProviderModelMapping(
            sonnet: emptyToNil(trimmed(sonnet)),
            sonnetName: emptyToNil(trimmed(sonnetName)),
            opus: emptyToNil(trimmed(opus)),
            opusName: emptyToNil(trimmed(opusName)),
            fable: emptyToNil(trimmed(fable)),
            fableName: emptyToNil(trimmed(fableName)),
            haiku: emptyToNil(trimmed(haiku)),
            haikuName: emptyToNil(trimmed(haikuName)),
            subagent: emptyToNil(trimmed(subagent))
        )
        return mapping.isEmpty ? nil : mapping
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
