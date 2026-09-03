import SwiftUI

extension ProviderTool {
    /// 工具在界面中的本地化名称。
    func displayName(in strings: Strings) -> String {
        switch self {
        case .claudeCode: return strings.providerToolClaudeCode
        case .codex: return strings.providerToolCodex
        }
    }
}

/// 供应商页面的宿主场景。
///
/// 菜单栏空间有限，只负责把新增操作路由到设置页；完整表单仅在设置窗口中展示。
enum ProviderSwitchPresentation: Equatable {
    case settings
    case menuBar

    var showsInlineAddProviderButton: Bool {
        self == .settings
    }

    var showsFooterAddProviderLink: Bool {
        self == .menuBar
    }

    /// 供应商管理菜单（编辑、复制启动命令、删除）统一在卡片中提供。
    var showsProfileManagementMenu: Bool {
        true
    }

    /// 复制入口已融入卡片更多菜单。
    var showsLaunchCommandCopyButton: Bool {
        false
    }

    var addProviderRoute: ProviderSwitchAddProviderRoute {
        switch self {
        case .settings:
            return .profileEditor
        case .menuBar:
            return .providerSettings
        }
    }
}

/// 「新增供应商」入口的目标，用于保持菜单栏与设置页行为明确且可测试。
enum ProviderSwitchAddProviderRoute: Equatable {
    case profileEditor
    case providerSettings
}

/// 供应商切换设置页（卡片式 UI 对齐最新设计稿）：
/// - 分段选择器：Claude Code / Codex 全宽胶囊分段切换
/// - 卡片列表：官方卡片 + Profile 卡片栈，激活项带有系统蓝外边框与「使用中」绿色胶囊微章；Profile 卡片右侧均展示 `•••` 更多操作菜单
/// - 设置窗口：展示全宽「+ 新增供应商」主按钮并打开新增表单
/// - 菜单栏：将新增操作放入底部链接（「编辑配置文件」左侧）并路由到供应商设置页
/// - 底部辅助：居中展示供应商相关文字链接
/// - 异常状态：未托管 / 损坏卡片视觉融入卡片体系
struct ProviderSwitchSettingsView: View {
    /// 工具分段选中底块 matchedGeometry 标识：底块在分段间平滑滑移。
    private static let toolSegmentIndicatorID = "provider-tool-segment-active"

    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    var presentation: ProviderSwitchPresentation = .settings
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }
    var commandCopier: ProviderLaunchCommandCopying = ProviderLaunchCommandCopier()

    @Namespace private var toolSegmentIndicator
    @State private var selectedTool: ProviderTool = .claudeCode
    @State private var addingProfileForTool: ProviderTool?
    @State private var editingProfile: ProviderProfile?
    @State private var deletingProfile: ProviderProfile?
    @State private var adoptingName = ""
    @State private var confirmingRebuildTool: ProviderTool?
    @State private var editorTool: ProviderTool?
    @State private var backupTool: ProviderTool?
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolSegment

            // 工具分段主体：id 随 selectedTool 变化触发整组 peer 淡切，
            // 底部静态链接随整组统一过渡。
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 8) {
                        officialCard

                        let profiles = manager.profiles(for: selectedTool)
                        ForEach(profiles) { profile in
                            profileCard(profile)
                        }
                    }

                    unmanagedCard
                    corruptedCard

                    if presentation.showsInlineAddProviderButton {
                        addProviderButton
                    }

                    footerLinks
                }
                .id(selectedTool)
                .peerTransition()
            }
            .animation(Theme.Animation.pageTransition, value: selectedTool)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .providerToast(message: $toastMessage)
        .sheet(item: $addingProfileForTool) { tool in
            ProfileEditorView(manager: manager, strings: strings, tool: tool)
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(manager: manager, strings: strings, tool: profile.tool, profile: profile)
        }
        .sheet(item: $editorTool) { tool in
            ConfigFileEditorView(manager: manager, strings: strings, tool: tool)
        }
        .sheet(item: $backupTool) { tool in
            BackupRestoreView(manager: manager, strings: strings, tool: tool)
        }
        .alert(strings.providerUnmanagedAdoptPrompt, isPresented: $adoptPromptPresented) {
            TextField(strings.providerUnmanagedAdoptPlaceholder, text: $adoptingName)
            Button(strings.providerFormSave) { performAdopt() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            Text(String(format: strings.providerActiveUnmanagedSummaryFormat, unmanagedSummary))
        }
        .confirmationDialog(
            strings.providerDeleteConfirmTitle,
            isPresented: $deletePromptPresented,
            titleVisibility: .visible
        ) {
            Button(strings.providerDeleteConfirmButton, role: .destructive) { performDelete() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            Text(String(
                format: strings.providerDeleteConfirmMessageFormat,
                deletingProfile?.name ?? ""
            ))
        }
        .confirmationDialog(
            strings.providerCorruptedRebuildConfirmTitle,
            isPresented: $rebuildPromptPresented,
            titleVisibility: .visible
        ) {
            Button(strings.providerCorruptedBackupAndRebuild) { performRebuild() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            Text(strings.providerCorruptedRebuildConfirmMessage)
        }
    }

    // MARK: - 分段选择器

    private var toolSegment: some View {
        HStack(spacing: 0) {
            ForEach(ProviderTool.allCases) { tool in
                let isSelected = selectedTool == tool
                Button {
                    selectedTool = tool
                } label: {
                    Text(tool.displayName(in: strings))
                        .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.white)
                                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.06), radius: 2, x: 0, y: 1)
                                        .matchedGeometryEffect(id: Self.toolSegmentIndicatorID, in: toolSegmentIndicator)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        // 动画统一由 value 驱动，底块滑移与下方内容转场同享一套曲线。
        .animation(Theme.Animation.pageTransition, value: selectedTool)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color(red: 0xEB / 255.0, green: 0xEB / 255.0, blue: 0xED / 255.0))
        )
    }

    // MARK: - 官方卡片

    private var officialCard: some View {
        let isActive = isOfficialActive
        return HStack(spacing: 12) {
            Button {
                if !isActive {
                    activateOfficial()
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ProviderBrandVisual.officialColor(for: selectedTool))
                            .frame(width: 36, height: 36)
                        // 显式约束尺寸：GlyphView 内部 GeometryReader 是贪婪布局，不约束会撑爆卡片。
                        ProviderLogoGlyphView(layers: ProviderBrandVisual.officialLogo(for: selectedTool))
                            .frame(width: 36, height: 36)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.providerOfficial)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text(officialCaption)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive {
                inUseBadge
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground(isActive: isActive))
        .overlay(cardBorder(isActive: isActive))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var officialCaption: String {
        switch selectedTool {
        case .claudeCode: return strings.providerOfficialClaudeCaption
        case .codex: return strings.providerOfficialCodexCaption
        }
    }

    private var isOfficialActive: Bool {
        switch manager.active(tool: selectedTool) {
        case .official: return true
        case .profile, .unmanaged, .unreadable: return false
        }
    }

    // MARK: - Profile 卡片

    private func profileCard(_ profile: ProviderProfile) -> some View {
        let active = isActive(profile)
        let visual = ProviderBrandVisual.resolve(for: profile)
        let hostSummary = ProviderURLFormatter.hostOrSummary(from: profile.baseURL)

        return HStack(spacing: 12) {
            Button {
                if !active && profile.hasCompleteConnection {
                    activate(profile)
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(visual.color)
                            .frame(width: 36, height: 36)
                        if let logo = visual.logo {
                            ProviderLogoGlyphView(layers: logo)
                                .frame(width: 36, height: 36)
                        } else {
                            Text(visual.letter)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text(hostSummary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!profile.hasCompleteConnection)

            HStack(spacing: 8) {
                if active {
                    inUseBadge
                }

                if presentation.showsProfileManagementMenu {
                    Menu {
                        Button(strings.providerEdit) { editingProfile = profile }
                        Button(strings.providerCopyLaunchCommand) { copyLaunchCommand(for: profile) }
                        Button(strings.providerDelete, role: .destructive) {
                            deletingProfile = profile
                            deletePromptPresented = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.secondary.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground(isActive: active))
        .overlay(cardBorder(isActive: active))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func isActive(_ profile: ProviderProfile) -> Bool {
        manager.active(tool: selectedTool) == .profile(profileID: profile.id)
    }

    // MARK: - 徽章与卡片底板

    private var inUseBadge: some View {
        Text(strings.providerInUseBadge)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(red: 0x16 / 255.0, green: 0xA3 / 255.0, blue: 0x4A / 255.0))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0xDC / 255.0, green: 0xFC / 255.0, blue: 0xE7 / 255.0).opacity(colorScheme == .dark ? 0.25 : 0.85))
            )
    }

    private func cardBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
            .shadow(
                color: Color.black.opacity(colorScheme == .dark || isActive ? 0.0 : 0.03),
                radius: 2,
                x: 0,
                y: 1
            )
    }

    private func cardBorder(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isActive
                    ? Color.accentColor
                    : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)),
                lineWidth: isActive ? 1.5 : 0.8
            )
    }

    // MARK: - 「+ 新增供应商」主按钮

    private var addProviderButton: some View {
        Button {
            addProvider()
        } label: {
            HStack(spacing: 6) {
                Text(strings.providerAddProvider)
                    .font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(ProviderAddButtonStyle())
    }

    // MARK: - 居中辅助链接

    private var footerLinks: some View {
        HStack(spacing: 8) {
            if presentation.showsFooterAddProviderLink {
                Button(strings.providerAddProvider) {
                    addProvider()
                }
                .buttonStyle(ProviderFooterLinkButtonStyle())

                Text("·")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }

            Button(strings.providerEditConfigFile) {
                editorTool = selectedTool
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())

            Text("·")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.5))

            Button(strings.providerRestoreBackup) {
                backupTool = selectedTool
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    // MARK: - 未托管 / 损坏卡片

    @ViewBuilder
    private var unmanagedCard: some View {
        if case .unmanaged(let summary) = manager.active(tool: selectedTool) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(strings.providerActiveUnmanagedTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                }
                Text(String(format: strings.providerActiveUnmanagedSummaryFormat, summary))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(strings.providerUnmanagedAdopt) {
                        adoptingName = summary
                        adoptPromptPresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var corruptedCard: some View {
        if case .unreadable = manager.active(tool: selectedTool) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(strings.providerActiveUnreadableTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                }
                Text(strings.providerActiveUnreadableCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(strings.providerCorruptedBackupAndRebuild) {
                        confirmingRebuildTool = selectedTool
                        rebuildPromptPresented = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
            )
        }
    }

    // MARK: - 动作

    private func addProvider() {
        switch presentation.addProviderRoute {
        case .profileEditor:
            addingProfileForTool = selectedTool
        case .providerSettings:
            onOpenSettings(.providerSwitch)
        }
    }

    private var unmanagedSummary: String {
        guard case .unmanaged(let summary) = manager.active(tool: selectedTool) else { return "" }
        return summary
    }

    private func activate(_ profile: ProviderProfile) {
        do {
            present(outcome: try manager.switchTo(profile: profile))
        } catch {
            showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
        }
    }

    private func activateOfficial() {
        do {
            present(outcome: try manager.switchToOfficial(tool: selectedTool))
        } catch {
            showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
        }
    }

    private func copyLaunchCommand(for profile: ProviderProfile) {
        let message = commandCopier.copyLaunchCommand(for: profile)
            ? strings.providerLaunchCommandCopied
            : strings.providerLaunchCommandCopyFailed
        showToast(message)
    }

    private func present(outcome: ProviderSwitchOutcome) {
        let base: String
        switch outcome.target {
        case .official:
            base = strings.providerSwitchDoneOfficial
        case .profile(let name):
            base = String(format: strings.providerSwitchDoneFormat, name)
        }
        let hint = outcome.cliRunning
            ? String(format: strings.providerRestartRunningHintFormat, outcome.tool.displayName(in: strings))
            : strings.providerRestartHint
        showToast("\(base) · \(hint)")
    }

    private func performAdopt() {
        let name = adoptingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try manager.adoptUnmanaged(tool: selectedTool, name: name)
            showToast(String(format: strings.providerSwitchDoneFormat, name))
        } catch ProviderSwitchManagerError.missingUnmanagedValues {
            showToast(strings.providerUnmanagedAdoptError)
        } catch {
            showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
        }
    }

    private func performDelete() {
        guard let profile = deletingProfile else { return }
        do {
            try manager.deleteProfile(profile)
        } catch {
            showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
        }
    }

    private func performRebuild() {
        guard let tool = confirmingRebuildTool else { return }
        do {
            try manager.rebuildCorruptedConfig(tool: tool)
            showToast(strings.providerBackupRestored)
        } catch {
            showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
        }
    }

    // MARK: - 弹窗绑定

    @State private var adoptPromptPresented = false
    @State private var deletePromptPresented = false
    @State private var rebuildPromptPresented = false

    // MARK: - toast

    private func showToast(_ text: String) {
        withAnimation { toastMessage = text }
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }
}

// MARK: - 辅助样式与视觉解析

/// 新增供应商按钮样式（带 Hover 微反馈）
private struct ProviderAddButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : (isHovered ? 0.88 : 1.0))
            .onHover { isHovered = $0 }
    }
}

/// 底部副操作链接按钮样式（带 Hover 颜色过渡）
private struct ProviderFooterLinkButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
    }
}

/// 供应商品牌色与首字母视觉计算
enum ProviderBrandVisual {
    struct Visual {
        let letter: String
        let color: Color
        let logo: [ProviderLogoLayer]?

        init(letter: String, color: Color, logo: [ProviderLogoLayer]? = nil) {
            self.letter = letter
            self.color = color
            self.logo = logo
        }
    }

    static func resolve(for profile: ProviderProfile) -> Visual {
        visual(name: profile.name, baseURL: profile.baseURL)
    }

    static func visual(name: String, baseURL: String = "") -> Visual {
        let nameLower = name.lowercased()
        let urlLower = baseURL.lowercased()

        if nameLower.contains("glm") || nameLower.contains("智谱") || urlLower.contains("bigmodel") {
            return Visual(letter: "G", color: Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0), logo: ProviderLogoAssets.glm)
        }
        if nameLower.contains("kimi") || nameLower.contains("月之暗面") || urlLower.contains("moonshot") {
            return Visual(letter: "K", color: Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0), logo: ProviderLogoAssets.kimi)
        }
        if nameLower.contains("deepseek") || nameLower.contains("深度求索") || urlLower.contains("deepseek") {
            return Visual(letter: "D", color: Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0), logo: ProviderLogoAssets.deepseek)
        }
        if nameLower.contains("minimax") || urlLower.contains("minimax") {
            return Visual(letter: "M", color: Color(red: 0xEA / 255.0, green: 0x58 / 255.0, blue: 0x0C / 255.0), logo: ProviderLogoAssets.miniMax)
        }
        if nameLower.contains("openai") || nameLower.contains("chatgpt") || urlLower.contains("openai") {
            return Visual(letter: "O", color: Color(red: 0x10 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0), logo: ProviderLogoAssets.openai)
        }
        if nameLower.contains("anthropic") || nameLower.contains("claude") || urlLower.contains("anthropic") {
            return Visual(letter: "A", color: Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0), logo: ProviderLogoAssets.claude)
        }
        if nameLower.contains("qwen") || nameLower.contains("通义千问") || urlLower.contains("dashscope") || urlLower.contains("aliyun") {
            return Visual(letter: "Q", color: Color(red: 0x61 / 255.0, green: 0x5C / 255.0, blue: 0xED / 255.0))
        }
        if nameLower.contains("ollama") || urlLower.contains("11434") {
            return Visual(letter: "O", color: Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0))
        }

        // 自定义 / 兜底
        let initial: String
        if let first = name.first(where: { $0.isLetter || $0.isNumber }) {
            initial = String(first).uppercased()
        } else {
            initial = "P"
        }

        let palette: [Color] = [
            Color(red: 0x2F / 255.0, green: 0x80 / 255.0, blue: 0xED / 255.0),
            Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0),
            Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0),
            Color(red: 0x8B / 255.0, green: 0x5C / 255.0, blue: 0xF6 / 255.0),
            Color(red: 0xEC / 255.0, green: 0x48 / 255.0, blue: 0x99 / 255.0),
            Color(red: 0xF9 / 255.0, green: 0x73 / 255.0, blue: 0x16 / 255.0),
            Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0),
            Color(red: 0x06 / 255.0, green: 0xB6 / 255.0, blue: 0xD4 / 255.0),
        ]
        let hash = abs(name.hashValue)
        let color = palette[hash % palette.count]
        return Visual(letter: initial, color: color)
    }

    static func officialColor(for tool: ProviderTool) -> Color {
        switch tool {
        case .claudeCode:
            return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0) // 陶土色
        case .codex:
            return Color(red: 0x18 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0) // 曜石黑
        }
    }

    /// 官方卡片品牌 logo：Claude Code 用 Claude 花瓣标，Codex 用 OpenAI 结形标。
    static func officialLogo(for tool: ProviderTool) -> [ProviderLogoLayer] {
        switch tool {
        case .claudeCode: return ProviderLogoAssets.claude
        case .codex: return ProviderLogoAssets.openai
        }
    }
}

/// URL 格式化工具（提取简洁的 host/域名）
enum ProviderURLFormatter {
    static func hostOrSummary(from urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            if let port = url.port, port != 80, port != 443 {
                return "\(host):\(port)"
            }
            return host
        }
        var cleaned = trimmed
        if cleaned.hasPrefix("https://") {
            cleaned = String(cleaned.dropFirst("https://".count))
        } else if cleaned.hasPrefix("http://") {
            cleaned = String(cleaned.dropFirst("http://".count))
        }
        if let slashIndex = cleaned.firstIndex(of: "/") {
            cleaned = String(cleaned[..<slashIndex])
        }
        return cleaned.isEmpty ? trimmed : cleaned
    }
}

/// 轻量底部 toast：胶囊浮层，2.5 秒后自动消失（切换结果 / 错误提示）。
private struct ProviderToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: message)
    }
}

extension View {
    /// 供应商切换页共用 toast。
    func providerToast(message: Binding<String?>) -> some View {
        modifier(ProviderToastModifier(message: message))
    }
}
