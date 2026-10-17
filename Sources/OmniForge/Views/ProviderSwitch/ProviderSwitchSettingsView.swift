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

/// 供应商切换页（卡片列表风格，唯一入口为菜单栏控制中心 tab）：
/// - 分段选择器：Claude Code / Codex 复用 `PanelSegmentedControl`，右端齿轮
///   设置入口（对齐 Token 面板「限额显示」齿轮：popover 收纳底部链接动作）
/// - 卡片列表：官方行 + Profile 行各自成独立卡片（白底大圆角），激活卡片带 accent 描边
///   并展示「使用中」绿色胶囊微章，Profile 卡片右侧均展示 `•••` 更多操作菜单
/// - 新增供应商：齿轮弹层行动作在本容器打开完整表单（数据管理跟随使用层，不经设置窗中转）
/// - 齿轮弹层动作（新增供应商 / 编辑配置文件 / 恢复备份）作用于当前展示 tool
/// - 异常状态：未托管 / 损坏警示横幅以同款圆角卡片融入列表节奏
struct ProviderSwitchSettingsView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    /// 聚合编排管理器（nil = 未注册，降级为只显示直连页）。
    var aggregation: ProviderAggregationManager?
    var commandCopier: ProviderLaunchCommandCopying = ProviderLaunchCommandCopier()

    @State private var selectedTool: ProviderTool = .claudeCode
    /// 当前展示 tool 的快照：位于 Host 外，经 `onDisplayedSurfaceChange`
    /// 在挂载点（交换点）同步，保持顶栏操作目标与内容展示一致（SPEC §6.3.1）。
    @State private var displayedTool: ProviderTool = .claudeCode
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
    @State private var isTransitioningMode = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlCenterSizing) private var sizingContext

    init(
        manager: ProviderSwitchManager,
        strings: Strings,
        aggregation: ProviderAggregationManager?,
        commandCopier: ProviderLaunchCommandCopying = ProviderLaunchCommandCopier()
    ) {
        self.manager = manager
        self.strings = strings
        self.aggregation = aggregation
        self.commandCopier = commandCopier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionSwitcherRow

            // Claude Code / Codex 平级切换：按工具分段顺序方向化滑移（SPEC 三期），
            // 不再整树交叉淡化；Provider 状态（展开/编辑 sheet 目标）不随切换重建。
            // 内容与操作目标一律消费 Host 提供的 displayedTool（SPEC §6.3.1）：
            PageSwitchHost(
                requestedRoute: selectedTool,
                semantics: { from, to in
                    .lateral(from: from, to: to, order: ProviderTool.allCases)
                },
                surface: { _ in .clear },
                onDisplayedSurfaceChange: { tool, _ in displayedTool = tool },
                onRouteMountedBarrier: sizingContext.map { context in
                    { tool, proceed in
                        context.mountStarted(path: "provider/\(tool)", proceed: proceed)
                    }
                }
            ) { tool in
                // 内容与操作目标一律消费 Host 提供的 displayedTool（SPEC §6.3.1）：
                // exiting 期间旧 tool 内容保持可见，交换点才换成新 tool；
                // selectedTool 只承担导航请求职责。
                VStack(alignment: .leading, spacing: 10) {
                    if let aggregation, aggregation.isAggregating(tool) {
                        AggregationPanelView(
                            manager: aggregation,
                            switchManager: manager,
                            tool: tool,
                            strings: strings,
                            commandCopier: commandCopier,
                            onEditProfile: { profile in
                                editingProfile = profile
                            },
                            onDeleteProfile: { profile in
                                deletingProfile = profile
                                deletePromptPresented = true
                            }
                        )
                        .transition(.opacity)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            providerList(for: tool)

                            unmanagedBanner(for: tool)
                            corruptedBanner(for: tool)
                        }
                        .transition(.opacity)
                    }

                    footerLinks(for: tool)
                }
                .animation(Theme.Animation.snappy, value: aggregation?.isAggregating(tool))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .onChange(of: manager.profiles) { _, _ in
            // 聚合管理器只在启动时列举过一次 profile（`production()` 的快照）。用户新建/
            // 改名/删除供应商后必须重列，否则新 profile 进不了面板的「可加入」名单，
            // 作为默认那家时 `enterAggregation` 还会抛 profileNotFound（切换失败）。
            // 面板 `.task` 只覆盖「打开面板」这一次，这里补上面板开着时的增量。
            aggregation?.refresh()
        }
        .providerToast(message: $toastMessage)
        .sheet(item: $addingProfileForTool) { tool in
            ProfileEditorView(
                manager: manager,
                strings: strings,
                tool: tool,
                aggregating: aggregation?.isAggregating(tool) ?? false
            )
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(
                manager: manager,
                strings: strings,
                tool: profile.tool,
                profile: profile,
                // 打开时的模式快照：sheet 内容随 item 重建，聚合开关在模态下不可点，
                // 表单存续期内模式不会翻转。
                aggregating: aggregation?.isAggregating(profile.tool) ?? false
            )
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

    /// 聚合按钮悬停状态。
    @State private var isAggregationButtonHovered = false

    /// 「Claude Code / Codex」分段行：下划线 Tab + 右端聚合/直连切换按钮
    /// （右端切换按钮尺寸 26×26，与 Token 面板齿轮按钮完全对齐）。
    private var sectionSwitcherRow: some View {
        HStack(spacing: 8) {
            PanelSegmentedControl(
                options: ProviderTool.allCases.map { tool in
                    .init(tag: tool, title: tool.displayName(in: strings))
                },
                selection: $selectedTool,
                style: .underline
            )

            Spacer()

            aggregationSwitchButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// 聚合与直连切换按钮（位于顶栏右端，与 Token 面板齿轮 26×26 完全同构对齐）：
    /// - 直连模式（聚合关闭）：展示线条堆叠图标，hover 时加深
    /// - 聚合模式（聚合开启）：展示填充堆叠图标，带品牌强调蓝高亮背景与色调
    @ViewBuilder
    private var aggregationSwitchButton: some View {
        if let aggregation {
            let isAggregating = aggregation.isAggregating(displayedTool)
            Button {
                guard !isTransitioningMode else { return }
                if isAggregating {
                    exitAggregation(tool: displayedTool)
                } else {
                    enterAggregation(tool: displayedTool)
                }
            } label: {
                Image(systemName: isAggregating ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.system(size: 13, weight: isAggregating ? .semibold : .regular))
                    .foregroundStyle(
                        isAggregating
                            ? Theme.accentColor
                            : (isAggregationButtonHovered
                                ? (colorScheme == .light ? Theme.Stats.text1 : Color.white)
                                : (colorScheme == .light ? Theme.Stats.text2 : Color.secondary))
                    )
                    .frame(width: 26, height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isAggregating
                                    ? Theme.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12)
                                    : (isAggregationButtonHovered
                                        ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                        : Color.clear)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(isTransitioningMode)
            .onHover { hovering in
                withAnimation(Theme.Animation.hover) {
                    isAggregationButtonHovered = hovering
                }
            }
            .help(isAggregating ? strings.providerAggregationExit : strings.providerAggregationEnter)
            .accessibilityLabel(isAggregating ? strings.providerAggregationExit : strings.providerAggregationEnter)
            .accessibilityIdentifier(SettingsAccessibilityID.providerModeAggregationRow.rawValue)
        }
    }

    // MARK: - 居中辅助链接

    /// 快捷操作行：强调蓝链接 + 3×3 圆点分隔（#D1D1D6），间距 14。
    /// （对齐历史版本设计：纯蓝色文字，无按钮背景，居于页面最下方，直接点击操作）。
    private func footerLinks(for tool: ProviderTool) -> some View {
        HStack(spacing: 14) {
            Button(strings.providerAddProviderAction) {
                addProvider(tool: tool)
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())
            .accessibilityIdentifier(SettingsAccessibilityID.providerSwitchPopoverAddProvider.rawValue)

            linkDot

            Button(strings.providerEditConfigFile) {
                editorTool = tool
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())
            .accessibilityIdentifier(SettingsAccessibilityID.providerSwitchPopoverEditConfig.rawValue)

            linkDot

            Button(strings.providerRestoreBackup) {
                backupTool = tool
            }
            .buttonStyle(ProviderFooterLinkButtonStyle())
            .accessibilityIdentifier(SettingsAccessibilityID.providerSwitchPopoverRestoreBackup.rawValue)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 链接间分隔圆点（3×3，#D1D1D6）。
    private var linkDot: some View {
        Circle()
            .fill(ProviderCardVisual.linkDot)
            .frame(width: 3, height: 3)
    }

    // MARK: - 卡片列表

    /// 官方 + Profile 卡片列表：独立卡片，卡片间 10pt 间距（无发丝线体系）。
    private func providerList(for tool: ProviderTool) -> some View {
        VStack(alignment: .leading, spacing: ProviderCardVisual.cardSpacing) {
            // 直连互斥（SPEC 6.10）：该工具聚合生效时，直连「连接」会改写同一份
            // 客户端配置、静默破坏聚合投影——两个写者不得同时生效。
            if directActionsDisabled(for: tool) {
                PanelTintBanner(
                    icon: "lock.fill",
                    tint: .orange,
                    title: strings.providerAggregationDirectLockedReason,
                    message: nil
                )
            }

            officialCard(for: tool)

            let profiles = manager.profiles(for: tool)
            ForEach(profiles) { profile in
                profileCard(profile, tool: tool)
            }
        }
        .padding(.horizontal, 12)
    }

    /// 该工具聚合生效中 → 直连连接动作禁用（防止两个写者互相覆盖配置）。
    private func directActionsDisabled(for tool: ProviderTool) -> Bool {
        aggregation?.isAggregating(tool) == true
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))
                        Text(officialCaption(for: tool))
                            .font(.system(size: 12))
                            .foregroundStyle(ProviderCardVisual.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if isActive {
                        inUseBadge
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 聚合生效中禁用切官方（与 Profile 卡同一直连互斥规则，SPEC 6.10）。
            .disabled(directActionsDisabled(for: tool))
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
        case .profile, .unmanaged, .unreadable, .aggregating: return false
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
                } label: {                    HStack(spacing: 12) {
                        brandLogoBadge(
                            color: visual.color,
                            logo: visual.logo,
                            letter: visual.letter,
                            containerOverride: visual.containerColor,
                            logoTint: visual.logoTint
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))
                            Text(hostSummary)
                                .font(.system(size: 12))
                                .foregroundStyle(ProviderCardVisual.secondaryText(colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 连接不完整或聚合生效中 → 禁用（后者防两个写者互相覆盖配置）。
                .disabled(!profile.hasCompleteConnection || directActionsDisabled(for: tool))

                HStack(spacing: 8) {
                    if active {
                        inUseBadge
                    }

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
            .padding(12)
        }
    }

    // MARK: - 卡片容器与 logo 徽章

    /// 供应商卡片容器（设计稿三层强调）：
    /// - 普通卡：纯白底 + 发丝描边 + 黑 4% 轻投影
    /// - 选中卡：#FBFDFF 极浅蓝底 + 强调蓝 35% 描边 + 蓝色环境投影（y3 blur10）
    /// 投影挂在背景 shape 上，避免内容（文字）被一起虚化。
    private func providerCardContainer<Content: View>(
        isActive: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                    .fill(cardFill(isActive: isActive))
                    .overlay(
                        RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                            .strokeBorder(cardBorder(isActive: isActive), lineWidth: 1)
                    )
                    .shadow(
                        color: isActive
                            ? ProviderCardVisual.selectedCardShadow(colorScheme)
                            : ProviderCardVisual.normalCardShadow(colorScheme),
                        radius: isActive ? 10 : 4,
                        x: 0,
                        y: isActive ? 3 : 1
                    )
            )
    }

    private func cardFill(isActive: Bool) -> Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor)
            : (isActive ? ProviderCardVisual.selectedCardFill : ProviderCardVisual.normalCardFill)
    }

    private func cardBorder(isActive: Bool) -> Color {
        if isActive {
            return ProviderCardVisual.activeBorder(colorScheme)
        }
        return colorScheme == .dark ? Color.white.opacity(0.12) : ProviderCardVisual.border
    }

    /// 品牌 logo 徽章（设计稿 40×40 圆角容器）：品牌色底 + 真实厂商矢量 logo；
    /// 已知品牌可覆盖容器底色与 logo 填色（如 DeepSeek 浅蓝底 + 蓝标）。
    /// GlyphView 内部 GeometryReader 是贪婪布局，必须显式约束尺寸。
    private func brandLogoBadge(
        color: Color,
        logo: [ProviderLogoLayer]?,
        letter: String = "",
        containerOverride: Color? = nil,
        logoTint: Color? = nil
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: ProviderCardVisual.logoCornerRadius, style: .continuous)
                .fill(containerOverride ?? color)
                .frame(width: ProviderCardVisual.logoSize, height: ProviderCardVisual.logoSize)
            if let logo {
                ProviderLogoGlyphView(layers: logo, fill: AnyShapeStyle(logoTint ?? .white))
                    .frame(width: ProviderCardVisual.logoSize, height: ProviderCardVisual.logoSize)
            } else {
                Text(letter)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ProviderCardVisual.badgeText(colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(ProviderCardVisual.badgeBackground(colorScheme))
            )
    }

    /// 未托管 / 损坏警示横幅：tint 底圆角卡片，融入卡片列表节奏（视觉不变，
    /// 结构下沉到共享 `PanelTintBanner`，描边与圆角对齐卡片令牌）。
    private func warningBanner(
        icon: String,
        iconColor: Color,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        PanelTintBanner(
            icon: icon,
            tint: iconColor,
            title: title,
            message: message,
            cornerRadius: ProviderCardVisual.cornerRadius,
            bordered: true
        ) {
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.top, ProviderCardVisual.cardSpacing)
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

    /// 新增供应商在**当前容器**弹出表单（齿轮弹层动作触发），不再路由到设置窗
    /// ——数据管理跟随使用层。弹层动作先收起弹层再赋值，与同弹层的「编辑配置文件」
    /// 「恢复备份」一致。
    private func addProvider(tool: ProviderTool) {
        addingProfileForTool = tool
    }

    /// 收编确认弹层文案：按发起时捕获的 tool 取未托管摘要。
    private var unmanagedSummary: String {
        guard case .unmanaged(let summary) = manager.active(tool: adoptingTool) else { return "" }
        return summary
    }

    private func activate(_ profile: ProviderProfile) {
        Task { @MainActor in
            do {
                present(outcome: try await manager.switchTo(profile: profile))
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func activateOfficial(tool: ProviderTool) {
        Task { @MainActor in
            do {
                present(outcome: try await manager.switchToOfficial(tool: tool))
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
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

    private func aggregationSummary(aggregation: ProviderAggregationManager, tool: ProviderTool) -> String {
        ProviderModeRow.aggregationSummary(
            members: aggregation.members(tool: tool),
            joinableCount: aggregation.joinableProfileIDs(tool: tool).count,
            isAggregating: aggregation.isAggregating(tool),
            strings: strings
        )
    }

    private func enterAggregation(tool: ProviderTool) {
        guard let aggregation else { return }
        guard let candidate = defaultCandidateID(for: tool) else { return }
        isTransitioningMode = true
        Task { @MainActor in
            defer { isTransitioningMode = false }
            do {
                try await aggregation.enterAggregationAsync(tool: tool, defaultProfileID: candidate)
                withAnimation(Theme.Animation.snappy) {
                    showToast(tool == .claudeCode
                        ? strings.providerAggregationEnteredClaude
                        : strings.providerAggregationEnteredCodex)
                }
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func exitAggregation(tool: ProviderTool) {
        guard let aggregation else { return }
        let defaultID = aggregation.members(tool: tool).first(where: { $0.isDefault })?.id
        isTransitioningMode = true
        Task { @MainActor in
            defer { isTransitioningMode = false }
            do {
                try await aggregation.exitAggregationAsync(tool: tool)
                let defaultName = defaultID.flatMap { id in
                    manager.profiles(for: tool).first(where: { $0.id == id })?.name
                } ?? defaultID ?? ""
                withAnimation(Theme.Animation.snappy) {
                    showToast(String(format: strings.providerAggregationExitedFormat, defaultName))
                }
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func defaultCandidateID(for tool: ProviderTool) -> String? {
        if let active = manager.active(tool: tool).profileID,
           manager.profiles(for: tool).contains(where: { $0.id == active }) {
            return active
        }
        return manager.profiles(for: tool).first?.id
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

/// 供应商卡片视觉令牌（对齐设计稿）：
/// 浅色严格采用设计色值；深色设计稿未覆盖，语义色回退（同监控/Token 页策略）。
enum ProviderCardVisual {
    /// 卡片圆角（面板 18 / 卡片 14 / 分段 11 层级中的卡片档）。
    static let cornerRadius: CGFloat = 14
    /// 卡片间距（列表内相邻卡片、横幅与列表之间共用）。
    static let cardSpacing: CGFloat = 10
    /// logo 徽章边长与圆角（设计稿 40×40 容器）。
    static let logoSize: CGFloat = 40
    static let logoCornerRadius: CGFloat = 12

    /// 强调蓝 #0066CC（深色提亮保证对比度）。
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x40 / 255.0, green: 0x9C / 255.0, blue: 0xFF / 255.0)
            : Color(red: 0x00 / 255.0, green: 0x66 / 255.0, blue: 0xCC / 255.0)
    }

    /// 激活卡描边：强调蓝 35% 透明度（实色描边会很吵，35% 是设计关键值）。
    static func activeBorder(_ scheme: ColorScheme) -> Color {
        accent(scheme).opacity(0.35)
    }

    /// 非激活发丝描边。
    static let border = Color.primary.opacity(0.1)

    /// 主文字 #1D1D1F / 次文字 #7A7A7A（深色回退语义色）。
    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .primary : Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .secondary : Color(red: 0x7A / 255.0, green: 0x7A / 255.0, blue: 0x7A / 255.0)
    }

    /// 「使用中」Badge：底 #EBF7F0 / 字 #1F9D4D。
    static func badgeText(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x4A / 255.0, green: 0xDE / 255.0, blue: 0x80 / 255.0)
            : Color(red: 0x1F / 255.0, green: 0x9D / 255.0, blue: 0x4D / 255.0)
    }

    static func badgeBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x1F / 255.0, green: 0x9D / 255.0, blue: 0x4D / 255.0).opacity(0.18)
            : Color(red: 0xEB / 255.0, green: 0xF7 / 255.0, blue: 0xF0 / 255.0)
    }

    /// 普通卡片：纯白 + 黑 4% y1 blur4 轻投影。
    static let normalCardFill = Color.white
    static func normalCardShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.black.opacity(0.04)
    }

    /// 选中卡片：#FBFDFF 极浅蓝底 + 蓝色环境投影 rgba(0,102,204,0.10) y3 blur10。
    static let selectedCardFill = Color(red: 0xFB / 255.0, green: 0xFD / 255.0, blue: 0xFF / 255.0)
    static func selectedCardShadow(_ scheme: ColorScheme) -> Color {
        accent(scheme).opacity(scheme == .dark ? 0.16 : 0.10)
    }

    /// 快捷操作行分隔圆点 #D1D1D6。
    static let linkDot = Color(red: 0xD1 / 255.0, green: 0xD1 / 255.0, blue: 0xD6 / 255.0)
}

/// 底部副操作链接按钮样式（强调蓝 12px，无按钮背景，Hover 提亮反馈）
private struct ProviderFooterLinkButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(ProviderCardVisual.accent(colorScheme).opacity(isHovered ? 0.7 : 1.0))
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
        /// 卡片 logo 容器底色覆盖（nil = 用 color）：如 DeepSeek 浅蓝底（设计稿）。
        var containerColor: Color?
        /// logo 填色覆盖（nil = 白色）：如 DeepSeek 蓝色鲸标。
        var logoTint: Color?

        init(
            letter: String,
            color: Color,
            logo: [ProviderLogoLayer]? = nil,
            containerColor: Color? = nil,
            logoTint: Color? = nil
        ) {
            self.letter = letter
            self.color = color
            self.logo = logo
            self.containerColor = containerColor
            self.logoTint = logoTint
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
            return Visual(
                letter: "K",
                color: Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0),
                logo: ProviderLogoAssets.kimi,
                containerColor: Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0)
            )
        }
        if nameLower.contains("deepseek") || nameLower.contains("深度求索") || urlLower.contains("deepseek") {
            // 设计稿：浅蓝底 #E8F1FB + 强调蓝实心标（官方品牌视觉）。
            return Visual(
                letter: "D",
                color: Color(red: 0x00 / 255.0, green: 0x66 / 255.0, blue: 0xCC / 255.0),
                logo: ProviderLogoAssets.deepseek,
                containerColor: Color(red: 0xE8 / 255.0, green: 0xF1 / 255.0, blue: 0xFB / 255.0),
                logoTint: Color(red: 0x00 / 255.0, green: 0x66 / 255.0, blue: 0xCC / 255.0)
            )
        }
        if nameLower.contains("minimax") || urlLower.contains("minimax") {
            return Visual(letter: "M", color: Color(red: 0xEA / 255.0, green: 0x58 / 255.0, blue: 0x0C / 255.0), logo: ProviderLogoAssets.miniMax)
        }
        if nameLower.contains("阶跃") || nameLower.contains("stepfun") || urlLower.contains("stepfun") {
            // 品牌色与 TokenUsage 侧 stepfun 一致（#0057FF）。
            return Visual(letter: "S", color: Color(red: 0x00 / 255.0, green: 0x57 / 255.0, blue: 0xFF / 255.0), logo: ProviderLogoAssets.stepfun)
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
