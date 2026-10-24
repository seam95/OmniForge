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
/// - Claude 按打开时的模式二选一：直连 → 角色映射（含「声明支持 1M」复选）；
///   聚合 → 发布列表。Codex 恒为模型列表（首行默认）
/// - 底部取消与高亮保存主按钮
struct ProfileEditorView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    let tool: ProviderTool
    /// nil = 新增；非 nil = 编辑既有档案。
    var profile: ProviderProfile?
    /// 打开表单时该工具是否处于聚合模式（快照，打开期间不随顶栏开关重算）。
    /// Claude 分支据此二选一：聚合 → 只显示发布列表；直连 → 只显示角色映射
    /// （对齐 cc-switch classic/stack 两种表单布局，由打开时所处的模式格决定）。
    var aggregating: Bool = false

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
    /// Codex 模型上下文窗口编辑态：与 `codexModelRows` **按位平行**（等长，空串 = 未配置）。
    /// 窗口在模型行第三列编辑；行增删时必须同步平移——否则删掉中间一行后，幸存行的窗口
    /// 还按原下标读取，每个模型都会拿到邻居的窗口。
    @State private var codexWindowRows: [String] = []
    /// Codex 模型思考档位编辑态（逗号分隔串，如 "none,low,high"）：与 `codexModelRows`
    /// **按位平行**（空串 = 未配置 = 默认八档）。行尾档位按钮展开编辑。
    @State private var codexLevelsRows: [String] = []
    /// Codex 模型默认思考档位编辑态：与 `codexModelRows` **按位平行**（空串 = 未设置）。
    @State private var codexDefaultLevelsRows: [String] = []
    /// 当前展开档位编辑区的模型行下标（nil = 全部收起；同时只展开一行）。
    @State private var expandedReasoningIndex: Int?
    /// Claude 聚合发布源编辑态（`stackModels`）：**nil = 用户没动过**（回显与保存都按表单
    /// 当前模型映射实时推导）；非 nil = 用户动过（含 `[]` = 主动清空，什么都不发布）。
    /// 三态不可混淆：nil 跟着映射、`[]` 什么都不发布、`[行]` 原样发布。
    @State private var editedStackRows: [ClaudeStackModel]?
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
    /// 连通性测试（拉模型列表口径）：进行中 / 结果 / Codex 回填弹窗开关。
    @State private var connectivityTesting = false
    @State private var connectivityResult: ProviderConnectivityResult?
    @State private var showModelPicker = false

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
        .sheet(isPresented: $showModelPicker) {
            if let result = connectivityResult, result.isSuccess {
                ProviderModelPickerSheet(
                    strings: strings,
                    fetchedModels: result.models,
                    configuredModels: codexModelRows
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty },
                    onApply: applyPickedModels
                )
            }
        }
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

            // Claude 按打开时的模式二选一（对齐 cc-switch classic/stack）：
            // 聚合 → 发布列表（无角色映射）；直连 → 角色映射（无发布列表）。
            // Codex 恒为模型列表（直连聚合同构，无二选一）。
            if tool == .claudeCode && aggregating {
                stackModelsSection
            } else {
                modelMappingSection
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
                    .onChange(of: baseURL) { _, _ in invalidateConnectivityResult() }
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
                .onChange(of: token) { _, _ in invalidateConnectivityResult() }
            }

            connectivityTestSection
        }
    }

    // MARK: - 连通性测试（拉模型列表口径：一次验证连通 + 鉴权）

    private var connectivityTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    runConnectivityTest()
                } label: {
                    HStack(spacing: 6) {
                        if connectivityTesting {
                            ProgressView()
                                .controlSize(.small)
                            Text(strings.providerConnectivityTesting)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .medium))
                            Text(strings.providerConnectivityTestButton)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(inputBackground)
                    .overlay(inputBorder)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRunConnectivityTest || connectivityTesting)

                if let result = connectivityResult {
                    Text(connectivityMessage(for: result))
                        .font(.system(size: 12.5))
                        .foregroundStyle(result.isSuccess ? Color.green : Color.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    // Codex：成功后可勾选回填模型列表；Claude 角色映射形态不同，不回填。
                    if tool == .codex, result.isSuccess {
                        Button(strings.providerConnectivityPickModels) {
                            showModelPicker = true
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                    }
                } else {
                    Spacer()
                }
            }
        }
    }

    private var canRunConnectivityTest: Bool {
        !trimmed(baseURL).isEmpty && !trimmed(token).isEmpty
    }

    /// 连接参数变化后旧结果不再可信（尤其是成功结果会放出「选择模型」入口）——
    /// 清掉结果并收起弹窗，避免用旧供应商的模型列表回填新配置。
    private func invalidateConnectivityResult() {
        connectivityResult = nil
        showModelPicker = false
    }

    private func runConnectivityTest() {
        connectivityTesting = true
        connectivityResult = nil
        let tester = ProviderConnectivityTester()
        let base = baseURL
        let credential = token
        let targetTool = tool
        Task {
            let result = await tester.test(baseURL: base, token: credential, tool: targetTool)
            await MainActor.run {
                connectivityTesting = false
                connectivityResult = result
            }
        }
    }

    /// 结果 → 展示文案（成功绿 / 失败红）。
    private func connectivityMessage(for result: ProviderConnectivityResult) -> String {
        switch result.outcome {
        case .success(let models):
            return String(
                format: strings.providerConnectivitySuccessFormat,
                "\(result.latencyMilliseconds ?? 0)",
                models.count
            )
        case .authRejected(let status):
            return String(format: strings.providerConnectivityAuthRejectedFormat, "\(status)")
        case .endpointMissing:
            return strings.providerConnectivityEndpointMissing
        case .networkFailure(let reason):
            return String(format: strings.providerConnectivityNetworkFailureFormat, reason)
        case .serverError(let status, let body):
            return String(format: strings.providerConnectivityServerErrorFormat, status, body)
        }
    }

    /// 应用勾选的模型回表单（Codex）：按模型名保留既有显示名、窗口与档位，
    /// 新行补空串；平行数组重新对齐。
    /// 全部取消勾选时保留一个空行——模型列表的既有不变量是「至少一行」
    /// （空行保存后被 `alignedCodexSaveRows` 丢弃，语义等于「不指定模型」，但 UI 不会塌成空列表）。
    private func applyPickedModels(_ models: [String]) {
        var oldDisplay: [String: String] = [:]
        var oldWindows: [String: String] = [:]
        var oldLevels: [String: String] = [:]
        var oldDefaults: [String: String] = [:]
        for (index, raw) in codexModelRows.enumerated() {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            oldDisplay[model] = index < codexDisplayNameRows.count ? codexDisplayNameRows[index] : ""
            oldWindows[model] = index < codexWindowRows.count ? codexWindowRows[index] : ""
            oldLevels[model] = index < codexLevelsRows.count ? codexLevelsRows[index] : ""
            oldDefaults[model] = index < codexDefaultLevelsRows.count ? codexDefaultLevelsRows[index] : ""
        }
        let target = models.isEmpty ? [""] : models
        codexModelRows = target
        codexDisplayNameRows = target.map { oldDisplay[$0] ?? "" }
        codexWindowRows = target.map { oldWindows[$0] ?? "" }
        codexLevelsRows = target.map { oldLevels[$0] ?? "" }
        codexDefaultLevelsRows = target.map { oldDefaults[$0] ?? "" }
        expandedReasoningIndex = nil
        syncCodexParallelRows()
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
                    mappingRowWithOneM(label: strings.providerModelFallbackLabel, text: $model, placeholder: "glm-5.3")
                    mappingRowWithOneM(label: strings.providerSonnetModelLabel, text: $sonnet, placeholder: "glm-5.3")
                    mappingRowWithOneM(label: strings.providerOpusModelLabel, text: $opus, placeholder: "glm-5.3")
                    mappingRowWithOneM(label: strings.providerFableModelLabel, text: $fable, placeholder: "glm-5.3")
                    mappingRowWithOneM(label: strings.providerHaikuModelLabel, text: $haiku, placeholder: "glm-5.3-flash")
                    mappingRowWithOneM(label: strings.providerSubagentModelLabel, text: $subagent, placeholder: "glm-5.3")
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
                        codexWindowRows.append("")
                        codexLevelsRows.append("")
                        codexDefaultLevelsRows.append("")
                        syncCodexParallelRows()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                    }
                    .buttonStyle(.plain)
                    .help(strings.providerCodexModelsAdd)
                }

                ForEach(codexModelRows.indices, id: \.self) { index in
                    VStack(spacing: 6) {
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

                            // 上下文窗口（可选）：纯数字 tokens，留空 = 未配置（聚合按 272K 工作窗口）
                            TextField(
                                strings.providerCodexModelWindowPlaceholder,
                                text: codexWindowBinding(index)
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .frame(width: 110, height: 32)
                            .background(mappingInputBackground)
                            .overlay(mappingInputBorder)
                            .help(strings.providerCodexModelWindowHelp)

                            // 思考档位（可选）：徽章 + 展开箭头，展开区编辑该行档位
                            reasoningBadgeButton(index)

                            // 保留一行：删空后仍能改回「不指定模型」
                            if codexModelRows.count > 1 {
                                Button {
                                    codexModelRows.remove(at: index)
                                    codexDisplayNameRows.remove(at: index)
                                    codexWindowRows.remove(at: index)
                                    codexLevelsRows.remove(at: index)
                                    codexDefaultLevelsRows.remove(at: index)
                                    expandedReasoningIndex = nil
                                    syncCodexParallelRows()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
                                }
                                .buttonStyle(.plain)
                                .help(strings.providerCodexModelsDelete)
                            }
                        }

                        if expandedReasoningIndex == index {
                            reasoningLevelsEditor(index)
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

    /// 编辑区当前显示的行：用户动过就用编辑态，**没动过按表单当前映射实时推导**——
    /// 对齐 cc-switch `shownClaudeStackRows = claudeStackRows ?? mappedClaudeStackRows`
    /// （`ProviderForm.tsx:683`，`mappedClaudeStackRows` 是 `useMemo` 跟着表单 env 变的）。
    /// 少了这层「实时」，用户改角色模型字段不会反映到发布列表，保存时还会把旧推导固化成显式
    /// `stackModels`——静默偏离（映射存新值、发布列表留旧值）。
    private var shownStackRows: [ClaudeStackModel] {
        editedStackRows ?? ClaudeStackModelsField.fromMapping(profile: draftProfile())
    }

    /// 编辑态与 `modelOverride`（`ANTHROPIC_MODEL`）的联动绑定：
    /// 第一行的模型变化时把默认兜底模型字段改成同一个值。
    /// 对齐 cc-switch `handleClaudeStackRowsChange`（`ProviderForm.tsx:685-691`）——
    /// 首行是默认模型；删光了不碰（无首行即无默认值可比，见 `ClaudeStackModelsField.defaultModel`）。
    private var stackRowsBinding: Binding<[ClaudeStackModel]> {
        Binding(
            get: { shownStackRows },
            set: { newRows in
                let previous = ClaudeStackModelsField.defaultModel(shownStackRows)
                editedStackRows = newRows
                if let next = ClaudeStackModelsField.defaultModel(newRows), next != previous {
                    model = next
                }
            }
        )
    }

    /// 保存用的发布源（normalize 后）：
    /// - **直连模式打开（列表不可见）→ 原值保留**（`existing`；新增档案为 nil = 跟着映射推导）。
    ///   发布列表没显示给用户，保存不得触碰它——直连改映射就覆盖显式 `stackModels` 是静默偏离。
    /// - 聚合模式打开：
    ///   - 动过 → normalize 编辑态。**`[]` 是非 nil 的空数组**，`??` 不会用推导值顶掉它——
    ///     用户主动清空必须落成空数组（什么都不发布），回落 nil 会让下次打开又长出推导模型。
    ///   - 没动过 → normalize 推导值：本次保存把「跟着映射」固化成显式列表，值与当前映射一致。
    static func stackModelsForSave(
        _ edited: [ClaudeStackModel]?,
        profile: ProviderProfile,
        aggregating: Bool = true,
        existing: [ClaudeStackModel]? = nil
    ) -> [ClaudeStackModel]? {
        guard aggregating else { return existing }
        return ClaudeStackModelsField.normalize(edited ?? ClaudeStackModelsField.fromMapping(profile: profile))
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
                Button(strings.providerReasoningEffortUltra) {
                    reasoningEffort = "ultra"
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
        case "ultra": return strings.providerReasoningEffortUltra
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

    /// 带「声明支持 1M」复选的映射行（直连表单，对齐 cc-switch classic 映射的 1M 列）：
    /// 1M 以模型值字面 `[1M]` 后缀承载，直连写入 env 与聚合发布识别同键同源——
    /// 映射推导的发布条目无需结构变化即被发布方按字面标记认出。
    private func mappingRowWithOneM(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)

            TextField(placeholder, text: oneMAwareTextBinding(text))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(mappingInputBackground)
                .overlay(mappingInputBorder)

            Toggle(isOn: oneMToggleBinding(text)) {
                Text(strings.providerStackModelsOneM)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
            }
            .toggleStyle(.checkbox)
            .frame(width: 52, alignment: .leading)
        }
    }

    /// 1M 感知的映射文本绑定：输入框只显示剥掉 `[1M]` 后的基础名；
    /// 写回时按当前勾选态补标记——已勾状态下输入新模型名，1M 声明不丢。
    private func oneMAwareTextBinding(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { ClaudeStackModelsField.stripOneMMarker(text.wrappedValue).model },
            set: { newValue in
                let oneM = ClaudeStackModelsField.hasOneMMarker(text.wrappedValue)
                text.wrappedValue = ClaudeStackModelsField.setOneMMarker(newValue, oneM)
            }
        )
    }

    /// 映射行 1M 复选绑定：勾选 = 基础名补 `[1M]` 标记；去勾 = 剥标记（值空时两者皆空）。
    private func oneMToggleBinding(_ text: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { ClaudeStackModelsField.hasOneMMarker(text.wrappedValue) },
            set: { enabled in
                text.wrappedValue = ClaudeStackModelsField.setOneMMarker(text.wrappedValue, enabled)
            }
        )
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
            // 新增态：编辑态保持 nil（没动过），发布源由 stackRowsBinding 按 preset 刚带入的
            // 映射实时推导——用户之后改角色模型字段也会跟着变（对齐 cc-switch 的 ?? 回退）。
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
        // 窗口与 `codexModelList` 按位平行（落盘口径见 `ProviderProfile.codexModelEntries`）。
        codexWindowRows = profile.modelContextWindows ?? []
        codexLevelsRows = profile.modelReasoningLevels ?? []
        codexDefaultLevelsRows = profile.modelDefaultReasoningLevels ?? []
        syncCodexParallelRows()
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
        // 已存发布源原样回显；未配置（nil = 没动过）保持 nil，由 stackRowsBinding 按表单
        // 当前映射实时推导（SPEC §4；对齐 cc-switch `claudeStackRows ?? mappedClaudeStackRows`）。
        editedStackRows = profile.stackModels

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
                codexWindowRows = [""]
                codexLevelsRows = [""]
                codexDefaultLevelsRows = [""]
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
            displayNames: codexDisplayNameRows,
            windows: codexWindowRows,
            levels: codexLevelsRows,
            defaultLevels: codexDefaultLevelsRows
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
            // 聚合模式打开：normalize 后写入，**全空 → `[]`（用户主动清空、什么都不发布）**，
            // 绝不能折算成 nil（未配置）——否则下次打开又按映射长出模型，删除被静默还原。
            // 直连模式打开：发布列表不可见，保存用既有原值（对齐 cc-switch classic 保存
            // 不携带列表字段 → meta 原样保留），直连改映射不得覆盖显式配置的发布列表。
            stackModels: tool == .claudeCode
                ? ProfileEditorView.stackModelsForSave(
                    editedStackRows,
                    profile: draftProfile(),
                    aggregating: aggregating,
                    existing: self.profile?.stackModels
                )
                : nil,
            // 与 codexModels 同源过滤 → 按位对齐；一个都没配 → nil（不写键）
            codexModelDisplayNames: ProfileEditorView.codexDisplayNamesForSave(codexRows),
            // 窗口同样与 codexModels 同源过滤（删行不错位）；Claude 侧恒为空 → nil
            codexModelContextWindows: ProfileEditorView.codexContextWindowsForSave(codexRows),
            // 思考档位与默认档：同源过滤 + 规范化；Claude 侧恒空 → nil
            codexModelReasoningLevels: ProfileEditorView.codexReasoningLevelsForSave(codexRows),
            codexModelDefaultReasoningLevels: ProfileEditorView.codexDefaultReasoningLevelsForSave(codexRows)
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

    /// 上下文窗口编辑绑定：与模型行严格等长（越界读空串，写入忽略越界）。
    private func codexWindowBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < codexWindowRows.count ? codexWindowRows[index] : "" },
            set: { newValue in
                if index < codexWindowRows.count {
                    codexWindowRows[index] = newValue
                }
            }
        )
    }

    // MARK: - Codex 思考档位（行内展开编辑，对齐 cc-switch 行内可编辑集）

    /// 档位徽章按钮：未配置显示「自动」；已配置显示区间（low–max）或计数（N 档）。
    private func reasoningBadgeButton(_ index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedReasoningIndex = expandedReasoningIndex == index ? nil : index
            }
        } label: {
            HStack(spacing: 4) {
                Text(reasoningBadgeLabel(index))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(
                        reasoningLevelsFor(index) == nil
                            ? Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
                            : Color.accentColor
                    )
                    .lineLimit(1)
                Image(systemName: expandedReasoningIndex == index ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(mappingInputBackground)
            .overlay(mappingInputBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strings.providerCodexModelLevelsTitle)
    }

    /// 徽章文案：区间（连续）→ `low–max`；不连续 → `N 档`；未配置 → 「自动」。
    private func reasoningBadgeLabel(_ index: Int) -> String {
        guard let levels = reasoningLevelsFor(index), !levels.isEmpty else {
            return strings.providerCodexModelLevelsAuto
        }
        if let range = CodexReasoningLevel.summaryRange(for: levels) {
            return range.first == range.last ? range.first : "\(range.first)–\(range.last)"
        }
        return String(format: strings.providerCodexModelLevelsCountFormat, levels.count)
    }

    /// 该行解析后的档位列表（编辑中的原始串实时解析）。
    private func reasoningLevelsFor(_ index: Int) -> [String]? {
        guard index < codexLevelsRows.count else { return nil }
        return CodexReasoningLevel.parse(codexLevelsRows[index])
    }

    /// 展开的档位编辑区：七档复选（4+3 两行）+ 默认档位菜单。
    private func reasoningLevelsEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(strings.providerCodexModelLevelsTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary)

                Spacer()

                defaultReasoningLevelMenu(index)
            }

            HStack(spacing: 14) {
                ForEach(CodexReasoningLevel.ordered.prefix(4), id: \.self) { level in
                    reasoningLevelToggle(level, index: index)
                }
            }
            HStack(spacing: 14) {
                ForEach(CodexReasoningLevel.ordered.dropFirst(4), id: \.self) { level in
                    reasoningLevelToggle(level, index: index)
                }
            }
            Text(strings.providerCodexModelLevelsHint)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0))
        }
        .padding(10)
        .background(mappingInputBackground)
        .overlay(mappingInputBorder)
    }

    private func reasoningLevelToggle(_ level: String, index: Int) -> some View {
        let isOn = reasoningLevelsFor(index)?.contains(level) ?? false
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { enabled in toggleReasoningLevel(level, index: index, enabled: enabled) }
        )) {
            Text(level)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.primary)
        }
        .toggleStyle(.checkbox)
    }

    /// 勾选/去勾某档位：以解析后的规范列表重建逗号串（保持标准序）。
    private func toggleReasoningLevel(_ level: String, index: Int, enabled: Bool) {
        var levels = reasoningLevelsFor(index) ?? []
        if enabled {
            if !levels.contains(level) { levels.append(level) }
        } else {
            levels.removeAll { $0 == level }
        }
        let ordered = CodexReasoningLevel.ordered.filter { levels.contains($0) }
        if index < codexLevelsRows.count {
            codexLevelsRows[index] = ordered.joined(separator: ",")
            // 去勾后默认档可能已不在列表内——一并清掉，避免悬空引用。
            let fallback = index < codexDefaultLevelsRows.count ? codexDefaultLevelsRows[index] : ""
            if !fallback.isEmpty, !ordered.contains(fallback),
               index < codexDefaultLevelsRows.count {
                codexDefaultLevelsRows[index] = ""
            }
        }
    }

    /// 默认档位菜单：未设置 + 当前列表内档位（列表空时给全部七档——先选档位再选默认的顺序也合法）。
    private func defaultReasoningLevelMenu(_ index: Int) -> some View {
        let current = index < codexDefaultLevelsRows.count ? codexDefaultLevelsRows[index] : ""
        let levels = reasoningLevelsFor(index) ?? CodexReasoningLevel.ordered
        return Menu {
            Button(strings.providerCodexModelLevelsDefaultAuto) {
                if index < codexDefaultLevelsRows.count { codexDefaultLevelsRows[index] = "" }
            }
            Divider()
            ForEach(levels, id: \.self) { level in
                Button(level) {
                    if index < codexDefaultLevelsRows.count { codexDefaultLevelsRows[index] = level }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(strings.providerCodexModelLevelsDefaultLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x73 / 255.0))
                Text(current.isEmpty ? strings.providerCodexModelLevelsDefaultAuto : current)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(current.isEmpty ? Color.secondary : Color.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 显示名编辑态与模型行严格等长（平行数组的编辑侧不变量）。
    /// 窗口行与档位行共用同一条不变量（按位平行，越界按空串 = 未配置）。
    private func syncCodexParallelRows() {
        if codexDisplayNameRows.count > codexModelRows.count {
            codexDisplayNameRows = Array(codexDisplayNameRows.prefix(codexModelRows.count))
        } else if codexDisplayNameRows.count < codexModelRows.count {
            codexDisplayNameRows.append(
                contentsOf: Array(repeating: "", count: codexModelRows.count - codexDisplayNameRows.count)
            )
        }
        if codexWindowRows.count > codexModelRows.count {
            codexWindowRows = Array(codexWindowRows.prefix(codexModelRows.count))
        } else if codexWindowRows.count < codexModelRows.count {
            codexWindowRows.append(
                contentsOf: Array(repeating: "", count: codexModelRows.count - codexWindowRows.count)
            )
        }
        if codexLevelsRows.count > codexModelRows.count {
            codexLevelsRows = Array(codexLevelsRows.prefix(codexModelRows.count))
        } else if codexLevelsRows.count < codexModelRows.count {
            codexLevelsRows.append(
                contentsOf: Array(repeating: "", count: codexModelRows.count - codexLevelsRows.count)
            )
        }
        if codexDefaultLevelsRows.count > codexModelRows.count {
            codexDefaultLevelsRows = Array(codexDefaultLevelsRows.prefix(codexModelRows.count))
        } else if codexDefaultLevelsRows.count < codexModelRows.count {
            codexDefaultLevelsRows.append(
                contentsOf: Array(repeating: "", count: codexModelRows.count - codexDefaultLevelsRows.count)
            )
        }
    }

    /// Codex 待保存的（模型, 显示名, 窗口, 档位, 默认档）行：丢空白行与空行，
    /// **五个平行字段与模型同源过滤**——空白模型行被丢掉时它的平行字段必须一起丢，
    /// 否则平行数组整体串位（数据层容错不崩，只会静默显示错的名字/窗口/档位）。
    /// 平行字段短于模型（历史档案长度不齐）→ 越界按未配置补空。
    static func alignedCodexSaveRows(
        models: [String],
        displayNames: [String],
        windows: [String] = [],
        levels: [String] = [],
        defaultLevels: [String] = []
    ) -> [(model: String, displayName: String, window: String, levels: String, defaultLevel: String)] {
        var rows: [(model: String, displayName: String, window: String, levels: String, defaultLevel: String)] = []
        for (index, raw) in models.enumerated() {
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { continue }
            let displayName = index < displayNames.count
                ? displayNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let window = index < windows.count
                ? windows[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let levelList = index < levels.count
                ? levels[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let defaultLevel = index < defaultLevels.count
                ? defaultLevels[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            rows.append((model, displayName, window, levelList, defaultLevel))
        }
        return rows
    }

    /// 显示名平行数组的落盘值：一个都没配 → nil（不写 `model_display_names` 键，
    /// 保持新增档案的既有落盘形状）；有任一个非空 → 原样写（含空串占位，保住按位对齐）。
    static func codexDisplayNamesForSave(_ rows: [(model: String, displayName: String, window: String, levels: String, defaultLevel: String)]) -> [String]? {
        let names = rows.map(\.displayName)
        return names.allSatisfy { $0.isEmpty } ? nil : names
    }

    /// 窗口平行数组的落盘值：口径同显示名（一个都没配 → nil，不写键）。
    static func codexContextWindowsForSave(_ rows: [(model: String, displayName: String, window: String, levels: String, defaultLevel: String)]) -> [String]? {
        let windows = rows.map(\.window)
        return windows.allSatisfy { $0.isEmpty } ? nil : windows
    }

    /// 档位平行数组的落盘值：口径同显示名（规范化后全空 → nil，不写键）；
    /// 有配置时写规范化串（按标准序），非法输入被解析层过滤。
    static func codexReasoningLevelsForSave(_ rows: [(model: String, displayName: String, window: String, levels: String, defaultLevel: String)]) -> [String]? {
        let normalized = rows.map { row in
            CodexReasoningLevel.parse(row.levels)?.joined(separator: ",") ?? ""
        }
        return normalized.allSatisfy { $0.isEmpty } ? nil : normalized
    }

    /// 默认档位平行数组的落盘值：口径同显示名；默认档只在档位列表非空时保留
    /// （列表空 = 未配置档位覆盖，单独的默认档无意义且会被写入层忽略）。
    static func codexDefaultReasoningLevelsForSave(_ rows: [(model: String, displayName: String, window: String, levels: String, defaultLevel: String)]) -> [String]? {
        let normalized = rows.map { row in
            guard let levels = CodexReasoningLevel.parse(row.levels),
                  !levels.isEmpty,
                  CodexReasoningLevel.isValid(row.defaultLevel.lowercased()) else { return "" }
            return row.defaultLevel.lowercased()
        }
        return normalized.allSatisfy { $0.isEmpty } ? nil : normalized
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
    /// - `codexModelContextWindows`：Codex 模型上下文窗口，与 `codexModels` 按位平行（空串 = 未配置）。
    ///   由 `alignedCodexSaveRows` 与模型行**同源过滤**后实时推导，不能再取既有档案的原数组——
    ///   删掉中间一行后模型会左移，原数组的下标就整体错位（每个模型拿到邻居的窗口）。
    ///
    /// 窗口在模型行第三列编辑，本保存路径负责把它与模型、显示名一起落盘。
    /// - `codexModelReasoningLevels` / `codexModelDefaultReasoningLevels`：思考档位与默认档，
    ///   口径同窗口（同源过滤 + 规范化）。
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
        codexModelDisplayNames: [String]?,
        codexModelContextWindows: [String]? = nil,
        codexModelReasoningLevels: [String]? = nil,
        codexModelDefaultReasoningLevels: [String]? = nil
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
            modelContextWindows: codexModelContextWindows,
            modelReasoningLevels: codexModelReasoningLevels,
            modelDefaultReasoningLevels: codexModelDefaultReasoningLevels,
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
