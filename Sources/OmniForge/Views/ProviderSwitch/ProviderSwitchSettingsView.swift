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
/// Claude Code / Codex 分段切换；官方行 + profile 列表（激活打勾、设为激活、编辑、删除）；
/// 未托管卡（一键收编）；损坏卡（备份并重建）；底部「新增 / 编辑配置文件 / 恢复备份」。
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
        VStack(alignment: .leading, spacing: 14) {
            toolSegment
            officialRow
            profileRows
            unmanagedCard
            corruptedCard
            footerActions
        }
        .padding(12)
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

    // MARK: - 分段

    private var toolSegment: some View {
        Picker("", selection: $selectedTool) {
            ForEach(ProviderTool.allCases) { tool in
                Text(tool.displayName(in: strings)).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - 官方行

    private var officialRow: some View {
        Button {
            activateOfficial()
        } label: {
            rowContent(
                title: strings.providerOfficial,
                subtitle: officialCaption,
                isActive: isOfficialActive
            )
        }
        .buttonStyle(.plain)
        .disabled(isOfficialActive)
    }

    /// 行内容：激活标记 + 标题 + 副标题。
    private func rowContent(title: String, subtitle: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            statusMark(isActive: isActive)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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

    // MARK: - profile 列表

    @ViewBuilder
    private var profileRows: some View {
        if manager.profiles(for: selectedTool).isEmpty {
            Text(strings.providerEmptyProfilesHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(manager.profiles(for: selectedTool)) { profile in
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        activate(profile)
                    } label: {
                        HStack(spacing: 8) {
                            statusMark(isActive: isActive(profile))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(profile.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isActive(profile) || !profile.hasCompleteConnection)

                    if !isActive(profile) {
                        Button(strings.providerSetActive) {
                            activate(profile)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!profile.hasCompleteConnection)
                    }
                    Menu {
                        Button(strings.providerEdit) { editingProfile = profile }
                        Button(strings.providerDelete, role: .destructive) { deletingProfile = profile }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 行首激活标记：激活打勾，未激活空心圆。
    private func statusMark(isActive: Bool) -> some View {
        Group {
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel(strings.providerActiveMark)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.title3)
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
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                addingProfileForTool = selectedTool
            } label: {
                Label(
                    String(format: strings.providerAddProfileFormat, selectedTool.displayName(in: strings)),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            HStack(spacing: 12) {
                Button(strings.providerEditConfigFile) {
                    editorTool = selectedTool
                }
                Button(strings.providerRestoreBackup) {
                    backupTool = selectedTool
                }
            }
            .font(.callout)
        }
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
            try manager.adoptUnmanaged(tool: selectedTool, name: name)
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
