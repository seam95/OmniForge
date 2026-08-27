import AppKit
import SwiftUI

/// 供应商表单的窗口布局策略。
///
/// 将屏幕边界计算与 SwiftUI 视图分离，便于用纯单元测试锁定小屏幕行为。
enum ProfileEditorLayout {
    static let editorWidth: CGFloat = 520
    static let preferredMaximumHeight: CGFloat = 720
    static let minimumHeight: CGFloat = 420
    static let footerHeight: CGFloat = 56
    static let separatorHeight: CGFloat = 1
    static let verticalScreenInset: CGFloat = 64
    static let fallbackVisibleScreenHeight: CGFloat = 900

    static func maxHeight(for visibleScreenHeight: CGFloat) -> CGFloat {
        guard visibleScreenHeight.isFinite, visibleScreenHeight > 0 else {
            return preferredMaximumHeight
        }

        let availableHeight = max(0, visibleScreenHeight - verticalScreenInset)
        let preferredHeight = min(preferredMaximumHeight, max(minimumHeight, availableHeight))
        return min(preferredHeight, visibleScreenHeight)
    }

    static func scrollViewportHeight(for visibleScreenHeight: CGFloat) -> CGFloat {
        max(
            0,
            maxHeight(for: visibleScreenHeight) - footerHeight - separatorHeight
        )
    }
}

/// 供应商档案表单（新增 / 编辑）：
/// 按照设计稿重构现代卡片式布局：
/// - 顶部清晰标题
/// - 预设供应商下拉（仅新增模式，带品牌色徽章图标与自动填充提示）
/// - 基础信息（名称、Base URL、带明密文切换的凭证）
/// - 模型映射（Claude Code 角色网格：默认兜底、Sonnet、Opus、Fable、Haiku、Subagent 及可折叠显示名）
/// - 底部取消与高亮保存主按钮
struct ProfileEditorView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    let tool: ProviderTool
    /// nil = 新增；非 nil = 编辑既有档案。
    var profile: ProviderProfile?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

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
    @State private var isTokenVisible = false
    @State private var showDisplayNames = false
    @State private var errorMessage: String?

    private var isEditing: Bool { profile != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                formContent
                    .padding(20)
            }
            .frame(maxHeight: scrollViewportHeight)

            Divider()
                .padding(.horizontal, 20)

            footerActions
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: ProfileEditorLayout.footerHeight)
        }
        .frame(width: ProfileEditorLayout.editorWidth)
        .frame(maxHeight: maxEditorHeight)
        .background(editorBackground)
        .onAppear(perform: loadInitialValues)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.primary)
                .padding(.top, 2)

            if !isEditing {
                presetSection
                sectionDivider
            }

            basicInfoSection

            sectionDivider

            modelMappingSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
                    .padding(.top, 2)
            }
        }
    }

    private var visibleScreenHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame.height ?? ProfileEditorLayout.fallbackVisibleScreenHeight
    }

    private var maxEditorHeight: CGFloat {
        ProfileEditorLayout.maxHeight(for: visibleScreenHeight)
    }

    private var scrollViewportHeight: CGFloat {
        ProfileEditorLayout.scrollViewportHeight(for: visibleScreenHeight)
    }

    private var editorBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)
    }

    // MARK: - 预设供应商分组

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings.providerPresetSectionTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)

            Menu {
                ForEach(ProviderPresetCatalog.builtins) { preset in
                    Button {
                        presetID = preset.id
                        applyPreset(preset.id)
                    } label: {
                        if presetID == preset.id {
                            Label(preset.displayName, systemImage: "checkmark")
                        } else {
                            Text(preset.displayName)
                        }
                    }
                }

                Divider()

                Button {
                    presetID = nil
                } label: {
                    if presetID == nil {
                        Label(strings.providerPresetNone, systemImage: "checkmark")
                    } else {
                        Text(strings.providerPresetNone)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    let visual = currentPresetVisual
                    ZStack {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(visual.color)
                            .frame(width: 18, height: 18)
                        if let logo = visual.logo {
                            // 同卡片：贪婪 GeometryReader 必须显式约束到色板尺寸。
                            ProviderLogoGlyphView(layers: logo)
                                .frame(width: 18, height: 18)
                        } else {
                            Text(visual.letter)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    Text(currentPresetDisplayName)
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(Color.primary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(inputBackground)
                .overlay(inputBorder)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 系统会把初始键盘焦点交给表单首个可聚焦控件（本下拉），禁用其蓝色焦点环
            .focusEffectDisabled(true)

            Text(strings.providerPresetHint)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
        }
    }

    private var currentPresetDisplayName: String {
        guard let id = presetID, let preset = ProviderPresetCatalog.preset(id: id) else {
            return strings.providerPresetNone
        }
        return preset.displayName
    }

    private var currentPresetVisual: ProviderBrandVisual.Visual {
        if let id = presetID, let preset = ProviderPresetCatalog.preset(id: id) {
            return ProviderBrandVisual.visual(name: preset.displayName, baseURL: preset.claudeCode?.baseURL ?? "")
        }
        return ProviderBrandVisual.visual(name: name.isEmpty ? strings.providerPresetNone : name, baseURL: baseURL)
    }

    // MARK: - 基础信息分组

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.providerBasicInfoSectionTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)

            // 名称
            VStack(alignment: .leading, spacing: 5) {
                Text(strings.providerNameLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))

                TextField("GLM 智谱", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(inputBackground)
                    .overlay(inputBorder)
            }

            // Base URL
            VStack(alignment: .leading, spacing: 5) {
                Text(strings.providerBaseURLLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))

                TextField("https://open.bigmodel.cn/api/anthropic", text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .textContentType(.URL)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(inputBackground)
                    .overlay(inputBorder)
            }

            // 凭证
            VStack(alignment: .leading, spacing: 5) {
                Text(strings.providerTokenLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))

                HStack(spacing: 8) {
                    if isTokenVisible {
                        TextField(strings.providerTokenPlaceholder, text: $token)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                    } else {
                        SecureField(strings.providerTokenPlaceholder, text: $token)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .textContentType(.password)
                    }

                    Button {
                        isTokenVisible.toggle()
                    } label: {
                        Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                    }
                    .buttonStyle(.plain)
                    .help(isTokenVisible ? "隐藏凭证" : "显示明文")
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(inputBackground)
                .overlay(inputBorder)
            }
        }
    }

    // MARK: - 模型映射分组

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tool == .claudeCode {
                HStack {
                    Text(strings.providerModelMappingSectionTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)

                    Spacer()

                    Text(strings.providerModelMappingDefaultHint)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                }

                VStack(spacing: 8) {
                    mappingRow(label: strings.providerModelFallbackLabel, text: $model, placeholder: "glm-5.3")
                    mappingRow(label: strings.providerSonnetModelLabel, text: $sonnet, placeholder: "glm-5.3")
                    mappingRow(label: strings.providerOpusModelLabel, text: $opus, placeholder: "glm-5.3")
                    mappingRow(label: strings.providerFableModelLabel, text: $fable, placeholder: "glm-5.3")
                    mappingRow(label: strings.providerHaikuModelLabel, text: $haiku, placeholder: "glm-5.3-flash")
                    mappingRow(label: strings.providerSubagentModelLabel, text: $subagent, placeholder: "glm-5.3")
                }

                Text(strings.providerModelMappingRoleHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                    .padding(.top, 2)

                // macOS 上 DisclosureGroup 的自定义文本 label 不响应点击（仅左侧箭头可点），
                // 因此自绘折叠行并显式接管点击，保证整行可切换
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDisplayNames.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showDisplayNames ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(strings.providerModelCustomDisplayNames)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showDisplayNames {
                    VStack(spacing: 8) {
                        mappingRow(label: strings.providerSonnetNameLabel, text: $sonnetName, placeholder: "", labelWidth: 92)
                        mappingRow(label: strings.providerOpusNameLabel, text: $opusName, placeholder: "", labelWidth: 92)
                        mappingRow(label: strings.providerFableNameLabel, text: $fableName, placeholder: "", labelWidth: 92)
                        mappingRow(label: strings.providerHaikuNameLabel, text: $haikuName, placeholder: "", labelWidth: 92)
                    }
                    .padding(.top, 6)
                }
            } else {
                // Codex
                Text(strings.providerModelLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)

                mappingRow(label: strings.providerModelLabel, text: $model, placeholder: "")

                Text(strings.providerModelHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
            }
        }
    }

    private func mappingRow(label: String, text: Binding<String>, placeholder: String, labelWidth: CGFloat = 74) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(mappingInputBackground)
                .overlay(mappingInputBorder)
        }
    }

    // MARK: - 底部操作栏

    private var footerActions: some View {
        HStack {
            Button(strings.providerFormCancel) {
                dismiss()
            }
            .buttonStyle(ProviderCancelButtonStyle())
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(strings.providerFormSave, action: save)
                .buttonStyle(ProviderSaveButtonStyle(enabled: canSave))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.top, 2)
    }

    // MARK: - 视觉样式辅助

    private var sectionDivider: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(0.08)
                    : Color(red: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xEA / 255.0)
            )
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color.white
            )
    }

    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                colorScheme == .dark
                    ? Color.white.opacity(0.14)
                    : Color(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0),
                lineWidth: 1
            )
    }

    private var mappingInputBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color.white
            )
    }

    private var mappingInputBorder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                colorScheme == .dark
                    ? Color.white.opacity(0.14)
                    : Color(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0),
                lineWidth: 1
            )
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

        if !sonnetName.isEmpty || !opusName.isEmpty || !fableName.isEmpty || !haikuName.isEmpty {
            showDisplayNames = true
        }
    }

    /// 从 preset 带入连接参数（仅新增模式；编辑模式下 preset 下拉隐藏）。
    private func applyPreset(_ id: String?) {
        guard let id, let preset = ProviderPresetCatalog.preset(id: id) else { return }
        switch tool {
        case .claudeCode:
            if let connection = preset.claudeCode {
                name = preset.displayName
                baseURL = connection.baseURL
                model = connection.defaultModel
                sonnet = connection.modelMapping?.sonnet ?? connection.defaultModel
                sonnetName = connection.modelMapping?.sonnetName ?? ""
                opus = connection.modelMapping?.opus ?? connection.defaultModel
                opusName = connection.modelMapping?.opusName ?? ""
                fable = connection.modelMapping?.fable ?? connection.defaultModel
                fableName = connection.modelMapping?.fableName ?? ""
                haiku = connection.modelMapping?.haiku ?? connection.defaultModel
                haikuName = connection.modelMapping?.haikuName ?? ""
                subagent = connection.modelMapping?.subagent ?? connection.defaultModel
                extraEnv = connection.extraEnv
            }
        case .codex:
            if let connection = preset.codex {
                name = preset.displayName
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

// MARK: - 按钮样式

/// 取消按钮样式
private struct ProviderCancelButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(isHovered ? Color.primary : Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
    }
}

/// 保存主按钮样式
private struct ProviderSaveButtonStyle: ButtonStyle {
    let enabled: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        enabled
                            ? (isHovered ? Color(red: 0x00 / 255.0, green: 0x77 / 255.0, blue: 0xED / 255.0) : Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0))
                            : Color.gray.opacity(0.35)
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .onHover { isHovered = $0 }
    }
}
