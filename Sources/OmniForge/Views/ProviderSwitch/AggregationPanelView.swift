import SwiftUI

/// 聚合面板：状态行 + 三区名单（默认 / 已添加 / 可用）+ 成员卡片（模型 id 预览）+
/// 加入入口 + 模式动作（进入/退出 + 确认框）+ 代理未运行横幅 + Codex 陈旧客户端横幅 +
/// 缓存提示。进入/退出都经 `ProviderAggregationManager` 编排（先起代理后写配置）。
struct AggregationPanelView: View {
    @ObservedObject var manager: ProviderAggregationManager
    @ObservedObject var switchManager: ProviderSwitchManager
    let tool: ProviderTool
    let strings: Strings

    @State private var confirmingEnter = false
    @State private var confirmingExit = false
    @State private var confirmingRestartDaemon = false
    /// 刚退出的默认那家 id（「撤销」用——重新进入聚合）。
    @State private var undoDefaultID: String?
    @State private var toastMessage: String?

    @Environment(\.colorScheme) private var colorScheme

    init(
        manager: ProviderAggregationManager,
        switchManager: ProviderSwitchManager,
        tool: ProviderTool,
        strings: Strings
    ) {
        self.manager = manager
        self.switchManager = switchManager
        self.tool = tool
        self.strings = strings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusLine

                if manager.isAggregating(tool) {
                    proxyDownBanner
                    staleBanner
                    defaultSection
                    officialDefaultCodexHint
                    addedSection
                    availableSection
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .providerToast(message: $toastMessage)
        .confirmationDialog(
            strings.providerAggregationConfirmTitle,
            isPresented: $confirmingEnter,
            titleVisibility: .visible
        ) {
            Button(strings.providerAggregationEnter) { enterAggregation() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            enterConfirmMessage
        }
        .confirmationDialog(
            strings.providerAggregationExit,
            isPresented: $confirmingExit,
            titleVisibility: .visible
        ) {
            Button(strings.providerAggregationExit, role: .destructive) { exitAggregation() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            Text(strings.providerAggregationConfirmDirect)
        }
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
        .task { await manager.refreshStaleClients() }
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

    // MARK: - 状态行

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text(strings.providerAggregationStatusLead)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            let members = manager.members(tool: tool)
            if let defaultMember = members.first {
                Text(String(
                    format: strings.providerAggregationStatusValueFormat,
                    defaultMember.name,
                    members.count,
                    manager.publishedModels(tool: tool).count
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 进入 / 退出

    private var enterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            noteRow(strings.providerAggregationConfirmStack)
            noteRow(strings.providerAggregationNoteDefault)
            noteRow(strings.providerAggregationNoteNoFailover)
            if tool == .codex {
                noteRow(strings.providerAggregationNoteRestartCodex)
            }

            Button {
                confirmingEnter = true
            } label: {
                Text(strings.providerAggregationEnter)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(defaultCandidateID == nil)
            .accessibilityIdentifier(SettingsAccessibilityID.providerAggregationEnter.rawValue)
        }
    }

    private var exitAction: some View {
        Button {
            confirmingExit = true
        } label: {
            Text(strings.providerAggregationExit)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(SettingsAccessibilityID.providerAggregationExit.rawValue)
    }

    private func undoAction(defaultID: String) -> some View {
        Button {
            confirmingEnter = true
            undoDefaultID = defaultID
        } label: {
            Text(strings.providerAggregationUndo)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private var enterConfirmMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.providerAggregationConfirmStack)
            Text(strings.providerAggregationConfirmDirect)
            Text(strings.providerAggregationNoteDefault)
            Text(strings.providerAggregationNoteNoFailover)
            if tool == .codex {
                Text(strings.providerAggregationNoteRestartCodex)
            }
            if defaultCandidateIsOfficial {
                Text(strings.providerAggregationOfficialNote)
            }
        }
    }

    // MARK: - 三区名单

    private var defaultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(strings.providerAggregationSectionDefault)
            if let member = manager.members(tool: tool).first(where: { $0.isDefault }) {
                memberCard(member)
            }
        }
    }

    private var addedSection: some View {
        let others = manager.members(tool: tool).filter { !$0.isDefault }
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader(String(format: strings.providerAggregationSectionAddedFormat, others.count))
            ForEach(others) { member in
                memberCard(member)
            }
            if others.isEmpty {
                Text(strings.providerAggregationNoteEmpty)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var availableSection: some View {
        let candidates = joinCandidates
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader(String(format: strings.providerAggregationSectionAvailableFormat, candidates.count))
            ForEach(candidates) { profile in
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(strings.providerAggregationAdd) {
                        addMember(profile.id)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(ProviderCardVisual.normalCardFill)
                )
            }
            if hasOfficialExcluded {
                Text(strings.providerAggregationOfficialReason)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func memberCard(_ member: ProviderAggregationManager.AggregationMemberView) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(member.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))
                    .lineLimit(1)

                if member.isDefault {
                    Text(strings.providerAggregationSectionDefault)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }

                Spacer(minLength: 0)

                if member.isOfficial {
                    Text(strings.providerAggregationOfficialReason)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    if !member.isDefault {
                        Button(strings.providerAggregationSetDefault) {
                            setDefault(member.id)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    if showsRemoveButton(for: member.id) {
                        Button(strings.providerAggregationRemove) {
                            removeMember(member.id)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // 模型 id 预览：等宽字体 + 中间截断（长 id 不撑卡）。
            Text(member.modelIDs.joined(separator: "   "))
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(ProviderCardVisual.normalCardFill)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// 官方默认 Codex 提示行（见 `officialDefaultCodexHint`）：一行说明，不单独成分区。
    @ViewBuilder
    private var officialDefaultCodexHint: some View {
        if let hint = officialDefaultCodexHint(manager: manager) {
            noteRow(hint)
        }
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cacheHint: some View {
        Text(strings.providerAggregationCacheHint)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
    private func staleMessage(_ stale: CodexStaleClients) -> String? {
        if stale.daemon {
            return strings.providerAggregationStaleDaemonBody
        }
        if stale.others {
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
        Task { @MainActor in
            do {
                try manager.enterAggregation(tool: tool, defaultProfileID: candidate)
                showToast(tool == .claudeCode
                          ? strings.providerAggregationEnteredClaude
                          : strings.providerAggregationEnteredCodex)
            } catch {
                showToast(String(format: strings.providerSwitchFailedFormat, error.localizedDescription))
            }
        }
    }

    private func exitAggregation() {
        undoDefaultID = manager.members(tool: tool).first(where: { $0.isDefault })?.id
        Task { @MainActor in
            do {
                try manager.exitAggregation(tool: tool)
                showToast(String(
                    format: strings.providerAggregationExitedFormat,
                    undoDefaultID.map { id in
                        switchManager.profiles(for: tool).first(where: { $0.id == id })?.name ?? id
                    } ?? ""
                ))
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

    private func showToast(_ message: String) {
        toastMessage = message
    }
}
