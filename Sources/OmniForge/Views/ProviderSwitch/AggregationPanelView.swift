import SwiftUI

/// 聚合面板：聚合池成员卡片（默认高亮排首位 + 附属成员）+ 可加入候选卡片 +
/// 统一 40×40 品牌 Logo 与操作菜单 + 模式动作（进入/退出直切，无确认框）+
/// 代理未运行横幅 + Codex 陈旧客户端横幅 + 缓存提示。
/// 进入/退出都经 `ProviderAggregationManager` 编排（先起代理后写配置）。
struct AggregationPanelView: View {
    @ObservedObject var manager: ProviderAggregationManager
    @ObservedObject var switchManager: ProviderSwitchManager
    let tool: ProviderTool
    let strings: Strings
    var commandCopier: ProviderLaunchCommandCopying = ProviderLaunchCommandCopier()
    var onEditProfile: ((ProviderProfile) -> Void)? = nil
    var onDeleteProfile: ((ProviderProfile) -> Void)? = nil

    @State private var confirmingRestartDaemon = false
    /// 刚退出的默认那家 id（「撤销」用——重新进入聚合）。
    @State private var undoDefaultID: String?
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var isTransitioning = false

    @Environment(\.colorScheme) private var colorScheme

    init(
        manager: ProviderAggregationManager,
        switchManager: ProviderSwitchManager,
        tool: ProviderTool,
        strings: Strings,
        commandCopier: ProviderLaunchCommandCopying = ProviderLaunchCommandCopier(),
        onEditProfile: ((ProviderProfile) -> Void)? = nil,
        onDeleteProfile: ((ProviderProfile) -> Void)? = nil
    ) {
        self.manager = manager
        self.switchManager = switchManager
        self.tool = tool
        self.strings = strings
        self.commandCopier = commandCopier
        self.onEditProfile = onEditProfile
        self.onDeleteProfile = onDeleteProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ProviderCardVisual.cardSpacing) {
            if manager.isAggregating(tool) {
                proxyDownBanner
                staleBanner

                // 聚合成员列表（默认排在首位，带高亮描边与「默认」徽章）
                membersList

                officialDefaultCodexHint

                // 可加入候选列表（若存在候选者）
                if !joinCandidates.isEmpty {
                    availableSection
                } else if hasOfficialExcluded {
                    officialExcludedNote
                }

                exitAction
                if let undoDefaultID {
                    undoAction(defaultID: undoDefaultID)
                }
            } else {
                enterSection
                if let undoDefaultID {
                    undoAction(defaultID: undoDefaultID)
                }
            }

            cacheHint
        }
        .animation(Theme.Animation.snappy, value: manager.isAggregating(tool))
        .padding(.horizontal, 12)
        .providerToast(message: $toastMessage)
        .confirmationDialog(
            strings.providerAggregationRestartDaemonConfirmTitle,
            isPresented: $confirmingRestartDaemon,
            titleVisibility: .visible
        ) {
            Button(strings.providerAggregationRestartDaemon, role: .destructive) { restartDaemon() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            Text(strings.providerAggregationRestartDaemonConfirmMessage)
        }
        // 开面板即重新列举 profile：管理器构造时的那份快照是启动期的，用户此后新建/改名/
        // 删除的 profile 都不在里面（`production()` 在用户还没建任何东西时就快照了）。
        // 不刷新的话，新建的 profile 进不了「可加入」名单，作为默认那家时还会
        // `enterAggregation` 抛 profileNotFound（切换失败）。`ProviderSwitchManager`
        // 每次 upsert/delete 都自刷，这里补上聚合管理器这一侧。
        .task {
            manager.refresh()
            await manager.refreshStaleClients()
        }
    }

    // MARK: - 可测成员（纯函数：不依赖渲染）

    /// 可加入的 profile id（官方账号与在名单者除外）。
    func joinableProfileIDs(manager: ProviderAggregationManager) -> [String] {
        manager.joinableProfileIDs(tool: tool)
    }

    /// 默认那家不渲染移除按钮（聚合开启期间不可移除）。
    func showsRemoveButton(for profileID: String) -> Bool {
        guard let member = manager.members(tool: tool).first(where: { $0.id == profileID }) else {
            return false
        }
        return !member.isDefault
    }

    /// 直连互斥判定：该工具聚合生效时直连动作禁用（SPEC 6.10）。
    var directActionsDisabled: Bool {
        manager.isAggregating(tool)
    }

    /// 官方默认 Codex 提示（SPEC §3 / P0-3 契约第 2 条的 UI 面）：默认那家是 Codex 官方账号时
    /// 模型目录整体不写，成员模型不会出现在 Codex 的 `/model` 菜单——必须显式告知，
    /// 否则用户会以为名单里的模型都可用。
    ///
    /// 两个条件都必需：仅 Codex 侧有此行为（Claude 官方默认照走 BASE_URL + token 替换）；
    /// 且只在聚合生效且有默认那家时出现。
    func officialDefaultCodexHint(manager: ProviderAggregationManager) -> String? {
        guard tool == .codex,
              let member = manager.members(tool: tool).first(where: { $0.isDefault }),
              member.isOfficial else {
            return nil
        }
        return strings.providerAggregationOfficialDefaultCodexHint
    }

    // MARK: - 聚合池成员与候选列表

    private var membersList: some View {
        let members = manager.members(tool: tool)
        return VStack(alignment: .leading, spacing: ProviderCardVisual.cardSpacing) {
            ForEach(members) { member in
                memberCard(member)
            }
        }
    }

    private var availableSection: some View {
        let candidates = joinCandidates
        return VStack(alignment: .leading, spacing: ProviderCardVisual.cardSpacing) {
            Text(String(format: strings.providerAggregationSectionAvailableFormat, candidates.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.top, 4)

            ForEach(candidates) { profile in
                candidateCard(profile)
            }

            if hasOfficialExcluded {
                officialExcludedNote
            }
        }
    }

    private var officialExcludedNote: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(strings.providerAggregationOfficialReason)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 2)
    }

    // MARK: - 卡片渲染（同构架构）

    private func memberCard(_ member: ProviderAggregationManager.AggregationMemberView) -> some View {
        let visual = memberVisual(for: member)
        let profile = switchManager.profiles(for: tool).first(where: { $0.id == member.id })
        let hostSummary = memberHostSummary(member: member, profile: profile)

        return cardContainer(isDefault: member.isDefault) {
            HStack(spacing: 12) {
                ProviderBrandLogoBadge(
                    visual: visual,
                    size: ProviderCardVisual.logoSize,
                    cornerRadius: ProviderCardVisual.logoCornerRadius
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(member.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if !hostSummary.isEmpty {
                            Text(hostSummary)
                                .font(.system(size: 12))
                                .foregroundStyle(ProviderCardVisual.secondaryText(colorScheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if !member.modelIDs.isEmpty {
                            if !hostSummary.isEmpty {
                                Text("·")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondary.opacity(0.4))
                            }
                            HStack(spacing: 3) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 8.5))
                                Text(member.modelIDs.joined(separator: ", "))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(ProviderCardVisual.secondaryText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if member.isDefault {
                        Text(strings.providerAggregationSectionDefault)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Theme.accentColor.opacity(0.12))
                            )
                    } else if !member.isOfficial {
                        Button {
                            setDefault(member.id)
                        } label: {
                            Text(strings.providerAggregationSetDefault)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(Theme.accentColor.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    memberMenu(for: member, profile: profile)
                }
            }
            .padding(12)
        }
    }

    private func candidateCard(_ profile: ProviderProfile) -> some View {
        let visual = ProviderBrandVisual.resolve(for: profile)
        let hostSummary = ProviderURLFormatter.hostOrSummary(from: profile.baseURL)

        return cardContainer(isDefault: false) {
            HStack(spacing: 12) {
                ProviderBrandLogoBadge(
                    visual: visual,
                    size: ProviderCardVisual.logoSize,
                    cornerRadius: ProviderCardVisual.logoCornerRadius
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))
                        .lineLimit(1)

                    if !hostSummary.isEmpty {
                        Text(hostSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(ProviderCardVisual.secondaryText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        addMember(profile.id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text(strings.providerAggregationAdd)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Theme.accentColor.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)

                    candidateMenu(for: profile)
                }
            }
            .padding(12)
        }
    }

    private func cardContainer<Content: View>(
        isDefault: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                    .fill(cardFill(isDefault: isDefault))
                    .overlay(
                        RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                            .strokeBorder(cardBorder(isDefault: isDefault), lineWidth: 1)
                    )
                    .shadow(
                        color: isDefault
                            ? ProviderCardVisual.selectedCardShadow(colorScheme)
                            : ProviderCardVisual.normalCardShadow(colorScheme),
                        radius: isDefault ? 10 : 4,
                        x: 0,
                        y: isDefault ? 3 : 1
                    )
            )
    }

    private func cardFill(isDefault: Bool) -> Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor)
            : (isDefault ? ProviderCardVisual.selectedCardFill : ProviderCardVisual.normalCardFill)
    }

    private func cardBorder(isDefault: Bool) -> Color {
        if isDefault {
            return ProviderCardVisual.activeBorder(colorScheme)
        }
        return colorScheme == .dark ? Color.white.opacity(0.12) : ProviderCardVisual.border
    }

    // MARK: - 操作菜单（对齐直连）

    private func memberMenu(
        for member: ProviderAggregationManager.AggregationMemberView,
        profile: ProviderProfile?
    ) -> some View {
        Menu {
            if !member.isDefault {
                Button(strings.providerAggregationSetDefault) {
                    setDefault(member.id)
                }
            }
            if showsRemoveButton(for: member.id) {
                Button(strings.providerAggregationRemove, role: .destructive) {
                    removeMember(member.id)
                }
            }
            if let profile {
                Divider()
                Button(strings.providerEdit) {
                    onEditProfile?(profile)
                }
                Button(strings.providerCopyLaunchCommand) {
                    copyLaunchCommand(for: profile)
                }
                if !member.isDefault {
                    Button(strings.providerDelete, role: .destructive) {
                        onDeleteProfile?(profile)
                    }
                }
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

    private func candidateMenu(for profile: ProviderProfile) -> some View {
        Menu {
            Button(strings.providerAggregationAdd) {
                addMember(profile.id)
            }
            Divider()
            Button(strings.providerEdit) {
                onEditProfile?(profile)
            }
            Button(strings.providerCopyLaunchCommand) {
                copyLaunchCommand(for: profile)
            }
            Button(strings.providerDelete, role: .destructive) {
                onDeleteProfile?(profile)
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

    // MARK: - 视觉与辅助计算

    private func memberVisual(for member: ProviderAggregationManager.AggregationMemberView) -> ProviderBrandVisual.Visual {
        if member.isOfficial {
            let logo = ProviderBrandVisual.officialLogo(for: tool)
            let color = ProviderBrandVisual.officialColor(for: tool)
            return ProviderBrandVisual.Visual(letter: "", color: color, logo: logo)
        }
        if let profile = switchManager.profiles(for: tool).first(where: { $0.id == member.id }) {
            return ProviderBrandVisual.resolve(for: profile)
        }
        return ProviderBrandVisual.visual(name: member.name)
    }

    private func memberHostSummary(
        member: ProviderAggregationManager.AggregationMemberView,
        profile: ProviderProfile?
    ) -> String {
        if member.isOfficial {
            switch tool {
            case .claudeCode: return strings.providerOfficialClaudeCaption
            case .codex: return strings.providerOfficialCodexCaption
            }
        }
        guard let profile else { return "" }
        return ProviderURLFormatter.hostOrSummary(from: profile.baseURL)
    }

    // MARK: - 进入 / 退出 / 撤销

    private var enterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strings.providerModeAggregation)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))
                        Text(strings.providerAggregationConfirmStack)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    featurePointRow(icon: "star.fill", text: strings.providerAggregationNoteDefault)
                    featurePointRow(icon: "shield.fill", text: strings.providerAggregationNoteNoFailover)
                    if tool == .codex {
                        featurePointRow(icon: "arrow.clockwise", text: strings.providerAggregationNoteRestartCodex)
                    }
                    // 默认候选是官方账号时事前说明限制（原确认框内的提示，前移到点击前可见）。
                    if defaultCandidateIsOfficial {
                        featurePointRow(icon: "person.crop.circle", text: strings.providerAggregationOfficialNote)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : ProviderCardVisual.normalCardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: ProviderCardVisual.cornerRadius, style: .continuous)
                            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : ProviderCardVisual.border, lineWidth: 1)
                    )
                    .shadow(color: ProviderCardVisual.normalCardShadow(colorScheme), radius: 3, x: 0, y: 1)
            )

            Button {
                // 进入聚合无确认框：点击即执行，结果由 toast 反馈。
                enterAggregation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text(strings.providerAggregationEnter)
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(defaultCandidateID == nil || isTransitioning)
            .accessibilityIdentifier(SettingsAccessibilityID.providerAggregationEnter.rawValue)
        }
    }

    private func featurePointRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 12, height: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exitAction: some View {
        Button {
            // 退出聚合无确认框：点击即执行，结果由 toast 反馈。
            exitAggregation()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 11, weight: .semibold))
                Text(strings.providerAggregationExit)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : ProviderCardVisual.border, lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isTransitioning)
        // 「直连配置会先备份、退出时自动还原」原为退出确认框正文，改挂悬浮提示保留该事实。
        .help(strings.providerAggregationConfirmDirect)
        .padding(.top, 2)
        .accessibilityIdentifier(SettingsAccessibilityID.providerAggregationExit.rawValue)
    }

    private func undoAction(defaultID: String) -> some View {
        Button {
            // 撤销（重新进入聚合）同样无确认框：带上刚退出的默认那家直接进入。
            undoDefaultID = defaultID
            enterAggregation()
        } label: {
            Text(strings.providerAggregationUndo)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(isTransitioning)
        .foregroundStyle(Color.accentColor)
    }

    // MARK: - 提示行与缓存

    /// 官方默认 Codex 提示行（见 `officialDefaultCodexHint`）：一行说明，不单独成分区。
    @ViewBuilder
    private var officialDefaultCodexHint: some View {
        if let hint = officialDefaultCodexHint(manager: manager) {
            noteRow(hint)
        }
    }

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private var cacheHint: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(strings.providerAggregationCacheHint)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    // MARK: - 横幅

    @ViewBuilder
    private var proxyDownBanner: some View {
        if !manager.isProxyRunning {
            PanelTintBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: strings.providerAggregationProxyDown,
                message: nil
            ) {
                Button(strings.providerAggregationStartService) {
                    manager.recoverOnLaunch()
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
    }

    /// Codex 陈旧客户端横幅：目录陈旧 / 登录变了 / 进程表不可得三态标题 + 重启守护进程 +
    /// 关闭（写 ack，指纹再变才重现）。对齐 cc-switch `CodexStaleClientsNotice`。
    @ViewBuilder
    private var staleBanner: some View {
        if let stale = manager.staleClients, stale.daemon || stale.others || stale.loginChanged {
            PanelTintBanner(
                icon: "arrow.clockwise.circle.fill",
                tint: .blue,
                title: staleTitle(stale),
                message: staleMessage(stale)
            ) {
                HStack(spacing: 8) {
                    if stale.daemon {
                        Button(strings.providerAggregationRestartDaemon) {
                            confirmingRestartDaemon = true
                        }
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityIdentifier(SettingsAccessibilityID.providerAggregationRestartDaemon.rawValue)
                    }
                    Button(strings.menuClose) {
                        dismissStaleClients()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
        }
    }

    /// 三态标题（优先序对齐 cc-switch：`unverified` > `auth` > 目录陈旧）。
    private func staleTitle(_ stale: CodexStaleClients) -> String {
        if stale.unverified { return strings.providerAggregationStaleUnverifiedTitle }
        if stale.loginChanged { return strings.providerAggregationStaleLoginTitle }
        return strings.providerAggregationStaleDaemonTitle
    }

    /// 横幅正文：守护进程 / 其余客户端各一条指引；仅登录变了时标题自明（cc-switch 同款）。
    /// `unverified`（进程表读不出来）时不发正文：那一态下 `others` 只表示「你上次确认后
    /// 目录或登录变了」（`CodexStaleClientDetector`），并不等于「有客户端还在用旧目录」——
    /// 配 `providerAggregationStaleOthersBody` 会自相矛盾（标题才说不知道有谁在跑）。
    /// 非 `private`：与 `officialDefaultCodexHint` 同款，供单测直接锁定这条互斥规则。
    func staleMessage(_ stale: CodexStaleClients) -> String? {
        if stale.daemon {
            return strings.providerAggregationStaleDaemonBody
        }
        if stale.others, !stale.unverified {
            return strings.providerAggregationStaleOthersBody
        }
        return nil
    }

    // MARK: - 数据解析

    /// 可加入的 profile（同工具、非官方、未在名单）。
    private var joinCandidates: [ProviderProfile] {
        let ids = Set(joinableProfileIDs(manager: manager))
        return switchManager.profiles(for: tool).filter { ids.contains($0.id) }
    }

    /// 是否存在被排除的官方账号（名单外）——给行内说明。
    private var hasOfficialExcluded: Bool {
        switchManager.profiles(for: tool).contains { profile in
            ProviderAggregationManager.isOfficial(profile) && !manager.toolStack(tool).isMember(profile.id)
        }
    }

    /// 进入聚合的默认那家候选：当前激活的 profile，否则首个可加入的。
    private var defaultCandidateID: String? {
        if let active = switchManager.active(tool: tool).profileID,
           switchManager.profiles(for: tool).contains(where: { $0.id == active }) {
            return active
        }
        return switchManager.profiles(for: tool).first?.id
    }

    private var defaultCandidateIsOfficial: Bool {
        guard let id = defaultCandidateID,
              let profile = switchManager.profiles(for: tool).first(where: { $0.id == id }) else {
            return false
        }
        return ProviderAggregationManager.isOfficial(profile)
    }

    // MARK: - 动作

    private func enterAggregation() {
        let candidate = undoDefaultID ?? defaultCandidateID
        undoDefaultID = nil
        guard let candidate else { return }
        isTransitioning = true
        Task { @MainActor in
            defer { isTransitioning = false }
            do {
                try await manager.enterAggregationAsync(tool: tool, defaultProfileID: candidate)
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

    private func exitAggregation() {
        undoDefaultID = manager.members(tool: tool).first(where: { $0.isDefault })?.id
        isTransitioning = true
        Task { @MainActor in
            defer { isTransitioning = false }
            do {
                try await manager.exitAggregationAsync(tool: tool)
                withAnimation(Theme.Animation.snappy) {
                    showToast(String(
                        format: strings.providerAggregationExitedFormat,
                        undoDefaultID.map { id in
                            switchManager.profiles(for: tool).first(where: { $0.id == id })?.name ?? id
                        } ?? ""
                    ))
                }
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func addMember(_ profileID: String) {
        Task { @MainActor in
            do {
                try manager.addMember(profileID)
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func removeMember(_ profileID: String) {
        Task { @MainActor in
            do {
                try manager.removeMember(profileID)
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func setDefault(_ profileID: String) {
        Task { @MainActor in
            do {
                try manager.setDefault(profileID)
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func restartDaemon() {
        Task { @MainActor in
            let restarted = manager.restartCodexDaemon()
            showToast(restarted
                      ? strings.providerAggregationDaemonRestarted
                      : strings.providerAggregationDaemonNotRunning)
            await manager.refreshStaleClients()
        }
    }

    /// 关掉陈旧横幅：记下当前目录与登录指纹 → 重新检测（同一份不再提示，指纹再变才重现）。
    private func dismissStaleClients() {
        Task { @MainActor in
            manager.acknowledgeStaleClients()
            await manager.refreshStaleClients()
        }
    }

    private func copyLaunchCommand(for profile: ProviderProfile) {
        let message = commandCopier.copyLaunchCommand(for: profile)
            ? strings.providerLaunchCommandCopied
            : strings.providerLaunchCommandCopyFailed
        showToast(message)
    }

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
