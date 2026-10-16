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
    /// Codex 模型列表编辑态：第一行为默认模型，其余条目进入模型目录。
    @State private var codexModelRows: [String] = []
    /// Codex 模型显示名编辑态：与 `codexModelRows` **按位平行**（等长，空串 = 未配置）。
    @State private var codexDisplayNameRows: [String] = []
    /// Claude 聚合发布源编辑态（`stackModels`）：初始 = 已存值 ?? 按模型映射推导的回显。
    @State private var stackRows: [ClaudeStackModel] = []
    @State private var reasoningEffort = ""
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
            // 明确高度而非上限：ScrollView 垂直方向无固有高度，若只给 maxHeight
            // 会被压成 0，整个表单塌缩到「分隔线 + footer」（实测 57pt），
            // 再由系统 sheet 最小高度兜底成 330pt，内容显示不全。
            .frame(height: scrollViewportHeight)

            Divider()
                .padding(.horizontal, 20)

            footerActions
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: ProfileEditorLayout.footerHeight)
        }
        .frame(width: ProfileEditorLayout.editorWidth)
        // 同理：显式高度，保证滚动区 + 分隔线 + footer 精确闭合为预期总高。
        .frame(height: maxEditorHeight)
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

            if tool == .claudeCode {
                sectionDivider
                stackModelsSection
            }

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
                // Codex：模型列表 — 第一行为默认模型，全部条目写入模型目录
                HStack {
                    Text(strings.providerCodexModelsSectionTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary)

                    Spacer()

                    Button {
                        codexModelRows.append("")
                        codexDisplayNameRows.append("")
                        syncCodexDisplayNameRows()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                    }
                    .buttonStyle(.plain)
                    .help(strings.providerCodexModelsAdd)
                }

                ForEach(codexModelRows.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        // 显示名（可选）：留空用模型名（SPEC §7 / P1-8）
                        TextField(
                            strings.providerCodexModelDisplayNamePlaceholder,
                            text: codexDisplayNameBinding(index)
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(mappingInputBackground)
                        .overlay(mappingInputBorder)

                        TextField(
                            index == 0
                                ? strings.providerCodexModelsFirstPlaceholder
                                : strings.providerCodexModelsPlaceholder,
                            text: $codexModelRows[index]
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(width: 200, height: 32)
                        .background(mappingInputBackground)
                        .overlay(mappingInputBorder)

                        // 保留一行：删空后仍能改回「不指定模型」
                        if codexModelRows.count > 1 {
                            Button {
                                codexModelRows.remove(at: index)
                                codexDisplayNameRows.remove(at: index)
                                syncCodexDisplayNameRows()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                            }
                            .buttonStyle(.plain)
                            .help(strings.providerCodexModelsDelete)
                        }
                    }
                }

                Text(strings.providerCodexModelsHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))

                codexReasoningEffortRow
            }
        }
    }

    // MARK: - Claude 聚合发布源（stackModels）

    /// 聚合发布源编辑区（SPEC §4 / P1-5）：每行「显示名 / 实际请求模型 / 1M / 删除」。
    /// 首行即默认模型——它一变就同步上面的「默认兜底模型」字段（见 `stackRowsBinding`）。
    private var stackModelsSection: some View {
        ClaudeStackModelsField(rows: stackRowsBinding, strings: strings)
    }

    /// 编辑态与 `modelOverride`（`ANTHROPIC_MODEL`）的联动绑定：
    /// 第一行的模型变化时把默认兜底模型字段改成同一个值。
    /// 对齐 cc-switch `handleClaudeStackRowsChange`（`ProviderForm.tsx:685-691`）——
    /// 首行是默认模型；删光了不碰（无首行即无默认值可比，见 `ClaudeStackModelsField.defaultModel`）。
    private var stackRowsBinding: Binding<[ClaudeStackModel]> {
        Binding(
            get: { stackRows },
            set: { newRows in
                let previous = ClaudeStackModelsField.defaultModel(stackRows)
                stackRows = newRows
                if let next = ClaudeStackModelsField.defaultModel(newRows), next != previous {
                    model = next
                }
            }
        )
    }

    private var codexReasoningEffortRow: some View {
        HStack(spacing: 12) {
            Text(strings.providerReasoningEffortLabel)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)

            Menu {
                Button(strings.providerReasoningEffortDefault) {
                    reasoningEffort = ""
                }
                Divider()
                Button(strings.providerReasoningEffortNone) {
                    reasoningEffort = "none"
                }
                Button(strings.providerReasoningEffortMinimal) {
                    reasoningEffort = "minimal"
                }
                Button(strings.providerReasoningEffortLow) {
                    reasoningEffort = "low"
                }
                Button(strings.providerReasoningEffortMedium) {
                    reasoningEffort = "medium"
                }
                Button(strings.providerReasoningEffortHigh) {
                    reasoningEffort = "high"
                }
                Button(strings.providerReasoningEffortXHigh) {
                    reasoningEffort = "xhigh"
                }
                Button(strings.providerReasoningEffortMax) {
                    reasoningEffort = "max"
                }
            } label: {
                HStack {
                    Text(displayReasoningEffortText)
                        .font(.system(size: 13))
                        .foregroundStyle(reasoningEffort.isEmpty ? Color.secondary : Color.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(mappingInputBackground)
                .overlay(mappingInputBorder)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var displayReasoningEffortText: String {
        switch reasoningEffort {
        case "none": return strings.providerReasoningEffortNone
        case "minimal": return strings.providerReasoningEffortMinimal
        case "low": return strings.providerReasoningEffortLow
        case "medium": return strings.providerReasoningEffortMedium
        case "high": return strings.providerReasoningEffortHigh
        case "xhigh": return strings.providerReasoningEffortXHigh
        case "max": return strings.providerReasoningEffortMax
        default: return strings.providerReasoningEffortDefault
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
            // 新增态同样按模型映射回显发布源（此刻 preset 已带入映射值），
            // 与「打开既有未配置档案」一致：未配置 = 跟着映射，而不是空列表。
            stackRows = ClaudeStackModelsField.fromMapping(profile: draftProfile())
            return
        }
        name = profile.name
        baseURL = profile.baseURL
        token = profile.token
        model = tool == .codex ? "" : (profile.modelOverride ?? "")
        codexModelRows = profile.codexModelList
        codexDisplayNameRows = Self.alignedCodexSaveRows(
            models: codexModelRows,
            displayNames: profile.modelDisplayNames ?? []
        ).map(\.displayName)
        syncCodexDisplayNameRows()
        reasoningEffort = profile.reasoningEffort ?? ""
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
        // 已存发布源原样回显；未配置（nil）才按模型映射推导（SPEC §4）。
        stackRows = profile.stackModels ?? ClaudeStackModelsField.fromMapping(profile: profile)

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
                codexModelRows = [connection.defaultModel]
                codexDisplayNameRows = [""]
                reasoningEffort = ""
            }
        }
    }

    /// 由表单当前值构造的草稿档案（仅用于新增态的 stackModels 回显推导）。
    private func draftProfile() -> ProviderProfile {
        ProviderProfile(
            id: "",
            name: name,
            tool: tool,
            baseURL: baseURL,
            token: token,
            modelOverride: tool == .codex ? nil : emptyToNil(trimmed(model)),
            modelMapping: tool == .claudeCode ? makeMapping() : nil
        )
    }

    private func save() {
        let codexRows = Self.alignedCodexSaveRows(
            models: codexModelRows,
            displayNames: codexDisplayNameRows
        )
        let profile = makeProfile(
            name: trimmed(name),
            baseURL: trimmed(baseURL),
            token: trimmed(token),
            modelOverride: tool == .codex ? nil : emptyToNil(trimmed(model)),
            reasoningEffort: tool == .codex ? emptyToNil(trimmed(reasoningEffort)) : nil,
            codexModels: tool == .codex ? (codexRows.isEmpty ? nil : codexRows.map(\.model)) : nil,
            modelMapping: tool == .claudeCode ? makeMapping() : nil,
            extraEnv: tool == .claudeCode ? extraEnv : [:],
            // normalize 后写入；**全空 → `[]`（用户主动清空、什么都不发布）**，
            // 绝不能折算成 nil（未配置）——否则下次打开又按映射长出模型，删除被静默还原。
            stackModels: tool == .claudeCode ? ClaudeStackModelsField.normalize(stackRows) : nil,
            // 与 codexModels 同源过滤 → 按位对齐；一个都没配 → nil（不写键）
            codexModelDisplayNames: ProfileEditorView.codexDisplayNamesForSave(codexRows)
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

    /// Codex 显示名行的绑定：越界按空串（平行数组的编辑侧容错——不崩、不串到别的行）。
    private func codexDisplayNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < codexDisplayNameRows.count ? codexDisplayNameRows[index] : "" },
            set: { newValue in
                if index < codexDisplayNameRows.count {
                    codexDisplayNameRows[index] = newValue
                }
            }
        )
    }

    /// 显示名编辑态与模型行严格等长（平行数组的编辑侧不变量）。
    private func syncCodexDisplayNameRows() {
        if codexDisplayNameRows.count > codexModelRows.count {
            codexDisplayNameRows = Array(codexDisplayNameRows.prefix(codexModelRows.count))
        } else if codexDisplayNameRows.count < codexModelRows.count {
            codexDisplayNameRows.append(
                contentsOf: Array(repeating: "", count: codexModelRows.count - codexDisplayNameRows.count)
            )
        }
    }

    /// Codex 待保存的（模型, 显示名）行：丢空白行与空行，**显示名与模型同源过滤**——
    /// 空白模型行被丢掉时它的显示名必须一起丢，否则平行数组整体串位（数据层容错不崩，
    /// 只会静默显示错的名字）。显示名短于模型（历史档案长度不齐）→ 越界按未配置补空。
    static func alignedCodexSaveRows(
        models: [String],
        displayNames: [String]
    ) -> [(model: String, displayName: String)] {
        var rows: [(model: String, displayName: String)] = []
        for (index, raw) in models.enumerated() {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let displayName = index < displayNames.count
                ? displayNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            rows.append((model, displayName))
        }
        return rows
    }

    /// 显示名平行数组的落盘值：一个都没配 → nil（不写 `model_display_names` 键，
    /// 保持新增档案的既有落盘形状）；有任一个非空 → 原样写（含空串占位，保住按位对齐）。
    static func codexDisplayNamesForSave(_ rows: [(model: String, displayName: String)]) -> [String]? {
        let names = rows.map(\.displayName)
        return names.allSatisfy { $0.isEmpty } ? nil : names
    }

    /// 由「表单当前值 + 既有档案」构造待保存档案。
    ///
    /// 入参显式化而非直接读 `@State`：视图状态只在渲染生命周期内有效（未渲染的视图实例上
    /// 写 `@State` 再读回得到的是初值，已实证），单测因此无法直接驱动 `save()`；把构造拆成
    /// 纯函数即可覆盖「保存到底保留了哪些字段、丢了哪些字段」。
    ///
    /// `stackModels` / `codexModelDisplayNames` 是本表单两个新编辑区的当前值，**必须显式传入**：
    /// - `stackModels`：Claude 聚合发布源；`[]` = 用户主动清空（什么都不发布），与 nil
    ///   （未配置、按模型映射推导）语义相反——漏传会把「清空」静默还原成「跟着映射」。
    /// - `codexModelDisplayNames`：Codex 模型显示名，与 `codexModels` 按位平行（空串 = 未配置）。
    ///
    /// 窗口平行数组仍取既有档案（按 SPEC §7 只做数据层、无编辑 UI），保存路径是它唯一的保留点。
    func makeProfile(
        name: String,
        baseURL: String,
        token: String,
        modelOverride: String?,
        reasoningEffort: String?,
        codexModels: [String]?,
        modelMapping: ProviderModelMapping?,
        extraEnv: [String: String],
        stackModels: [ClaudeStackModel]?,
        codexModelDisplayNames: [String]?
    ) -> ProviderProfile {
        ProviderProfile(
            id: self.profile?.id ?? ProviderProfile.slugify(name),
            name: name,
            tool: tool,
            baseURL: baseURL,
            token: token,
            modelOverride: modelOverride,
            reasoningEffort: reasoningEffort,
            codexModels: codexModels,
            modelMapping: modelMapping,
            stackModels: stackModels,
            modelDisplayNames: codexModelDisplayNames,
            modelContextWindows: self.profile?.modelContextWindows,
            extraEnv: extraEnv,
            // 收编外部文件时保留原来源标记；本 App 新建一律打 omniforge
            managedBy: self.profile?.managedBy ?? ProviderProfile.managedByMarker
        )
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
