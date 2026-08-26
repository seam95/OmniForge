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

/// 供应商切换设置页（控制中心独立页 + 设置侧栏共用，SPEC 2.9）：
/// - 顶部：大标题「供应商」+ 右侧高亮「+ 新增供应商」主按钮
/// - 分段选择器：Claude Code / Codex 胶囊状分段切换
/// - 列表：官方行 + Profile 列表，包含精致分割线、激活状态（蓝色对勾 vs 灰色圆圈）、设为激活按钮与操作菜单（...）
/// - 底部：左侧「编辑配置文件」与「恢复备份」蓝色链接，右侧「切换后需重启 CLI 生效」提示
/// - 未托管 / 损坏卡：一键收编与备份重建
struct ProviderSwitchSettingsView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    var onOpenSettings: (SettingsToolbarTab?) -> Void = { _ in }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerView
            toolSegment
            providerList
            unmanagedCard
            corruptedCard
            footerActions
        }
        .padding(20)
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

    // MARK: - 顶部 Header

    private var headerView: some View {
        HStack(alignment: .center) {
            Text(strings.controlcenterTabProviderSwitch)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                addingProfileForTool = selectedTool
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text(strings.providerAddProvider)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 分段

    private var toolSegment: some View {
        HStack(spacing: 0) {
            ForEach(ProviderTool.allCases) { tool in
                let isSelected = selectedTool == tool
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTool = tool
                    }
                } label: {
                    Text(tool.displayName(in: strings))
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(nsColor: .controlColor))
                                        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - 列表

    private var providerList: some View {
        VStack(spacing: 0) {
            officialRow
            Divider()

            let profiles = manager.profiles(for: selectedTool)
            if profiles.isEmpty {
                // 如果没有第三方 profile，只展示官方行和分割线
            } else {
                ForEach(profiles) { profile in
                    profileRow(profile)
                    Divider()
                }
            }
        }
    }

    // MARK: - 官方行

    private var officialRow: some View {
        let isActive = isOfficialActive
        return HStack(spacing: 12) {
            Button {
                if !isActive {
                    activateOfficial()
                }
            } label: {
                HStack(spacing: 12) {
                    statusMark(isActive: isActive)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.providerOfficial)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(officialCaption)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isActive)

            if !isActive {
                Button(strings.providerSetActive) {
                    activateOfficial()
                }
                .buttonStyle(ProviderActionPillButtonStyle())
            }
        }
        .padding(.vertical, 10)
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

    // MARK: - Profile 行

    private func profileRow(_ profile: ProviderProfile) -> some View {
        let active = isActive(profile)
        return HStack(spacing: 12) {
            Button {
                if !active && profile.hasCompleteConnection {
                    activate(profile)
                }
            } label: {
                HStack(spacing: 12) {
                    statusMark(isActive: active)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(profile.baseURL)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(active || !profile.hasCompleteConnection)

            if !active {
                Button(strings.providerSetActive) {
                    activate(profile)
                }
                .buttonStyle(ProviderActionPillButtonStyle())
                .disabled(!profile.hasCompleteConnection)
            }

            Menu {
                Button(strings.providerEdit) { editingProfile = profile }
                Button(strings.providerDelete, role: .destructive) { deletingProfile = profile }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                        .frame(width: 26, height: 26)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 10)
    }

    /// 行首激活标记：激活蓝色实心打勾，未激活灰色空心圆。
    private func statusMark(isActive: Bool) -> some View {
        Group {
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel(strings.providerActiveMark)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 20, height: 20)
            }
        }
    }

    private func isActive(_ profile: ProviderProfile) -> Bool {
        manager.active(tool: selectedTool) == .profile(profileID: profile.id)
    }

    // MARK: - 未托管 / 损坏卡

    @ViewBuilder
    private var unmanagedCard: some View {
        if case .unmanaged(let summary) = manager.active(tool: selectedTool) {
            card(title: strings.providerActiveUnmanagedTitle) {
                Text(String(format: strings.providerActiveUnmanagedSummaryFormat, summary))
                    .font(.callout)
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
        }
    }

    @ViewBuilder
    private var corruptedCard: some View {
        if case .unreadable = manager.active(tool: selectedTool) {
            card(title: strings.providerActiveUnreadableTitle) {
                Text(strings.providerActiveUnreadableCaption)
                    .font(.callout)
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
        }
    }

    private func card(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 底部操作

    private var footerActions: some View {
        HStack(alignment: .center) {
            HStack(spacing: 16) {
                Button(strings.providerEditConfigFile) {
                    editorTool = selectedTool
                }
                .buttonStyle(ProviderLinkButtonStyle())

                Button(strings.providerRestoreBackup) {
                    backupTool = selectedTool
                }
                .buttonStyle(ProviderLinkButtonStyle())
            }

            Spacer()

            Text(strings.providerRestartHint)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    // MARK: - 动作

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

    // MARK: - 弹窗绑定（alert 的 isPresented 需要独立 @State 驱动）

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

/// 药丸/圆角小操作按钮样式（如「设为激活」）。
private struct ProviderActionPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.5)
    }
}

/// 蓝色链接文字按钮样式（如「编辑配置文件」、「恢复备份」）。
private struct ProviderLinkButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color.accentColor)
            .underline(isHovered)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
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
