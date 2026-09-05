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

/// 供应商切换设置页（卡片列表风格）：
/// - 分段选择器：Claude Code / Codex 复用 `PanelSegmentedControl`
/// - 卡片列表：官方行 + Profile 行各自成独立卡片（白底大圆角），激活卡片带 accent 描边
///   并展示「使用中」绿色胶囊微章，Profile 卡片右侧均展示 `•••` 更多操作菜单
/// - 设置窗口：展示全宽「+ 新增供应商」主按钮并打开新增表单
/// - 菜单栏：将新增操作放入底部链接（「编辑配置文件」左侧）并路由到供应商设置页
/// - 底部辅助：居中展示供应商相关文字链接
/// - 异常状态：未托管 / 损坏警示横幅以同款圆角卡片融入列表节奏
struct ProviderSwitchSettingsView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    var presentation: ProviderSwitchPresentation = .settings
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }
    var commandCopier: ProviderLaunchCommandCopying = ProviderLaunchCommandCopier()

    @State private var selectedTool: ProviderTool = .claudeCode
    @State private var addingProfileForTool: ProviderTool?
    @State private var editingProfile: ProviderProfile?
    @State private var deletingProfile: ProviderProfile?
    @State private var adoptingName = ""
    /// 发起收编的展示中工具（Host displayedTool，收编确认时使用发起时目标）。
    @State private var adoptingTool: ProviderTool = .claudeCode
    @State private var confirmingRebuildTool: ProviderTool?
    @State private var editorTool: ProviderTool?
    @State private var backupTool: ProviderTool?
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionSwitcherRow

            // Claude Code / Codex 平级切换：单活动树分阶段淡出后淡入（SPEC §6），
            // 不再整树交叉淡化；Provider 状态（展开/编辑 sheet 目标）不随切换重建。
            PageSwitchHost(
                requestedRoute: selectedTool,
                semantics: { _, _ in .peer },
                surface: { _ in .clear }
            ) { tool in
                // 内容与操作目标一律消费 Host 提供的 displayedTool（SPEC §6.3.1）：
                // exiting 期间旧 tool 内容保持可见，交换点才换成新 tool；
                // selectedTool 只承担导航请求职责。
                VStack(alignment: .leading, spacing: 0) {
                    providerList(for: tool)

                    unmanagedBanner(for: tool)
                    corruptedBanner(for: tool)

                    if presentation.showsInlineAddProviderButton {
                        addProviderButton(for: tool)
                    }

                    footerLinks(for: tool)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
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

    /// 「Claude Code / Codex」分段行：复用 Token 面板分段控件（底块滑移与内容淡切同享一套曲线）。
    private var sectionSwitcherRow: some View {
        PanelSegmentedControl(
            options: ProviderTool.allCases.map { tool in
                .init(tag: tool, title: tool.displayName(in: strings))
            },
            selection: $selectedTool
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - 卡片列表

    /// 官方 + Profile 卡片列表：独立卡片，卡片间 10pt 间距（无发丝线体系）。
    private func providerList(for tool: ProviderTool) -> some View {
        VStack(alignment: .leading, spacing: ProviderCardVisual.cardSpacing) {
            officialCard(for: tool)

            let profiles = manager.profiles(for: tool)
            ForEach(profiles) { profile in
                profileCard(profile, tool: tool)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 官方卡片

    private func officialCard(for tool: ProviderTool) -> some View {
        let isActive = isOfficialActive(tool: tool)
        return providerCardContainer(isActive: isActive) {
            Button {
                if !isActive {
                    activateOfficial(tool: tool)
                }
            } label: {
                HStack(spacing: 12) {
                    brandLogoBadge(
                        color: ProviderBrandVisual.officialColor(for: tool),
                        logo: ProviderBrandVisual.officialLogo(for: tool)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.providerOfficial)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text(officialCaption(for: tool))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if isActive {
                        inUseBadge
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func officialCaption(for tool: ProviderTool) -> String {
        switch tool {
        case .claudeCode: return strings.providerOfficialClaudeCaption
        case .codex: return strings.providerOfficialCodexCaption
        }
    }

    private func isOfficialActive(tool: ProviderTool) -> Bool {
        switch manager.active(tool: tool) {
        case .official: return true
        case .profile, .unmanaged, .unreadable: return false
        }
    }

    // MARK: - Profile 卡片

    private func profileCard(_ profile: ProviderProfile, tool: ProviderTool) -> some View {
        let active = isActive(profile, tool: tool)
        let visual = ProviderBrandVisual.resolve(for: profile)
        let hostSummary = ProviderURLFormatter.hostOrSummary(from: profile.baseURL)

        return providerCardContainer(isActive: active) {
            HStack(spacing: 12) {
                Button {
                    if !active && profile.hasCompleteConnection {
                        activate(profile)
                    }
                } label: {
                    HStack(spacing: 12) {
                        brandLogoBadge(color: visual.color, logo: visual.logo, letter: visual.letter)

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
            .padding(.vertical, 10)
        }
    }

    // MARK: - 卡片容器与 logo 徽章

    /// 供应商卡片容器：白底大圆角 + 发丝描边；激活卡片叠加 accent 描边。
    private func providerCardContainer<Content: View>(
        isActive: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : ProviderCardVisual.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? ProviderCardVisual.activeBorder
                            : (colorScheme == .dark ? Color.white.opacity(0.12) : ProviderCardVisual.border),
                        lineWidth: 1
                    )
            )
    }

    /// 品牌色 logo 徽章：圆角色块 + 真实厂商矢量 logo（无 logo 时回退首字母）。
    /// GlyphView 内部 GeometryReader 是贪婪布局，必须显式约束尺寸。
    private func brandLogoBadge(color: Color, logo: [ProviderLogoLayer]?, letter: String = "") -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: ProviderCardVisual.logoCornerRadius, style: .continuous)
                .fill(color)
                .frame(width: ProviderCardVisual.logoSize, height: ProviderCardVisual.logoSize)
            if let logo {
                ProviderLogoGlyphView(layers: logo)
                    .frame(width: ProviderCardVisual.logoSize, height: ProviderCardVisual.logoSize)
            } else {
                Text(letter)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }

    private func isActive(_ profile: ProviderProfile, tool: ProviderTool) -> Bool {
        manager.active(tool: tool) == .profile(profileID: profile.id)
    }

    // MARK: - 徽章与警示横幅

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

    /// 未托管 / 损坏警示横幅：tint 底圆角卡片，融入卡片列表节奏。
    private func warningBanner(
        icon: String,
        iconColor: Color,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                .fill(iconColor.opacity(colorScheme == .dark ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                .strokeBorder(iconColor.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 1)
        )
        .padding(.top, ProviderCardVisual.cardSpacing)
    }

    // MARK: - 「+ 新增供应商」主按钮

    private func addProviderButton(for tool: ProviderTool) -> some View {
        Button {
            addProvider(tool: tool)
        } label: {
            Text(strings.providerAddProvider)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                        .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(ProviderAddButtonStyle())
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - 居中辅助链接

    private func footerLinks(for tool: ProviderTool) -> some View {
        HStack(spacing: 8) {
            if presentation.showsFooterAddProviderLink {
                Button(strings.providerAddProvider) {
                    addProvider(tool: tool)
                }
                .buttonStyle(ProviderFooterLinkButtonStyle())

                Text("·")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }

            Button(strings.providerEditConfigFile) {
                editorTool = tool
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())

            Text("·")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.5))

            Button(strings.providerRestoreBackup) {
                backupTool = tool
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
    }

    // MARK: - 未托管 / 损坏警示

    @ViewBuilder
    private func unmanagedBanner(for tool: ProviderTool) -> some View {
        if case .unmanaged(let summary) = manager.active(tool: tool) {
            warningBanner(
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange,
                title: strings.providerActiveUnmanagedTitle,
                message: String(format: strings.providerActiveUnmanagedSummaryFormat, summary),
                actionTitle: strings.providerUnmanagedAdopt
            ) {
                // 记录发起时目标：确认动作作用于该 displayed tool（SPEC §6.3.1 操作目标）。
                adoptingName = summary
                adoptingTool = tool
                adoptPromptPresented = true
            }
        }
    }

    @ViewBuilder
    private func corruptedBanner(for tool: ProviderTool) -> some View {
        if case .unreadable = manager.active(tool: tool) {
            warningBanner(
                icon: "xmark.octagon.fill",
                iconColor: .red,
                title: strings.providerActiveUnreadableTitle,
                message: strings.providerActiveUnreadableCaption,
                actionTitle: strings.providerCorruptedBackupAndRebuild
            ) {
                confirmingRebuildTool = tool
                rebuildPromptPresented = true
            }
        }
    }

    // MARK: - 动作

    private func addProvider(tool: ProviderTool) {
        switch presentation.addProviderRoute {
        case .profileEditor:
            addingProfileForTool = tool
        case .providerSettings:
            onOpenSettings(.providerSwitch)
        }
    }

    /// 收编确认弹层文案：按发起时捕获的 tool 取未托管摘要。
    private var unmanagedSummary: String {
        guard case .unmanaged(let summary) = manager.active(tool: adoptingTool) else { return "" }
        return summary
    }

    private func activate(_ profile: ProviderProfile) {
        do {
            present(outcome: try manager.switchTo(profile: profile))
        } catch {
            showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
        }
    }

    private func activateOfficial(tool: ProviderTool) {
        do {
            present(outcome: try manager.switchToOfficial(tool: tool))
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
            _ = try manager.adoptUnmanaged(tool: adoptingTool, name: name)
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

/// 供应商卡片视觉常量（对齐设计稿）：白底大圆角卡片 + 放大 logo 徽章 + 激活 accent 描边。
enum ProviderCardVisual {
    /// 卡片圆角。
    static let cornerRadius: CGFloat = 14
    /// 卡片间距（列表内相邻卡片、横幅与列表之间共用）。
    static let cardSpacing: CGFloat = 10
    /// logo 徽章边长与圆角（品牌色底 + 厂商矢量 logo）。
    static let logoSize: CGFloat = 44
    static let logoCornerRadius: CGFloat = 12

    /// 浅色卡片底（深色场景由调用方使用 controlBackgroundColor）。
    static let background = Color.white

    /// 非激活描边：浅色极淡发丝，深色用白色低透明度（调用方分支）。
    static let border = Color.primary.opacity(0.1)

    /// 激活卡片描边（深浅色同源 accent，浅色下略收）。
    static var activeBorder: Color {
        Color.accentColor.opacity(0.55)
    }
}

/// 新增供应商按钮样式（带 Hover 微反馈）
private struct ProviderAddButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : (isHovered ? 0.88 : 1.0))
            .onHover { isHovered = $0 }
    }
}

/// 底部副操作链接按钮样式（accent 色，Hover 提亮反馈）
private struct ProviderFooterLinkButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .regular))
            .foregroundStyle(Color.accentColor.opacity(isHovered ? 0.7 : 1.0))
            .opacity(configuration.isPressed ? 0.6 : 1.0)
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
