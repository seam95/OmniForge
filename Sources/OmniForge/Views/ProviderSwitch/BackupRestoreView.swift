import SwiftUI

/// 恢复备份列表（SPEC 2.5）：展示目标工具的历史快照，手动恢复前二次确认。
///
/// 每份备份可展开查看其内容——恢复是破坏性操作，用户需要先看清将要写入什么
/// （列表原先只显示时间与文件名，无法核对内容）。
struct BackupRestoreView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    let tool: ProviderTool

    @Environment(\.dismiss) private var dismiss
    @State private var pendingRestore: ProviderBackup?
    @State private var errorMessage: String?
    /// 当前展开查看内容的备份 id（同一时间只展开一份，避免多份长文本同时铺开）。
    @State private var expandedBackupID: String?
    /// 已加载的备份内容缓存：按 id 缓存，展开/收起不重复读盘。
    @State private var contentCache: [String: String] = [:]
    /// 内容读取失败提示（按 id 记录）。
    @State private var contentErrors: [String: String] = [:]

    private var backups: [ProviderBackup] {
        manager.backups.filter { $0.tool == tool }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.providerBackupListTitle)
                .font(.headline)

            if backups.isEmpty {
                Text(strings.providerBackupEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(backups) { backup in
                    backupRow(backup)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(strings.providerFormCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        // 固定尺寸：列表需要足够高度容纳「展开内容」的文本区；内容区随窗口高度自适应。
        .frame(width: 460, height: 460)
        .confirmationDialog(
            strings.providerBackupRestoreConfirmTitle,
            isPresented: $restorePromptPresented,
            titleVisibility: .visible
        ) {
            Button(strings.providerBackupRestore, role: .destructive) { performRestore() }
            Button(strings.providerFormCancel, role: .cancel) {}
        } message: {
            Text(String(
                format: strings.providerBackupRestoreConfirmMessageFormat,
                pendingRestore?.id ?? ""
            ))
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func backupRow(_ backup: ProviderBackup) -> some View {
        let isExpanded = expandedBackupID == backup.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                    Text(backup.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                // 展开/收起内容（主操作之一，与「恢复」并列）。
                Button {
                    toggleContent(backup)
                } label: {
                    Label(
                        isExpanded ? strings.providerBackupHideContent : strings.providerBackupViewContent,
                        systemImage: isExpanded ? "chevron.down" : "chevron.right"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(strings.providerBackupRestore) {
                    pendingRestore = backup
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 2)

            if isExpanded {
                contentView(for: backup)
            }
        }
    }

    @ViewBuilder
    private func contentView(for backup: ProviderBackup) -> some View {
        if let message = contentErrors[backup.id] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let content = contentCache[backup.id] {
            ScrollView(.vertical) {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        } else {
            Text(strings.providerBackupContentLoading)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 动作

    /// 展开/收起：首次展开时读盘并缓存；再展开直接复用缓存。
    private func toggleContent(_ backup: ProviderBackup) {
        if expandedBackupID == backup.id {
            expandedBackupID = nil
            return
        }
        expandedBackupID = backup.id
        guard contentCache[backup.id] == nil, contentErrors[backup.id] == nil else { return }
        do {
            contentCache[backup.id] = try manager.backupContent(backup)
        } catch {
            contentErrors[backup.id] = strings.providerBackupContentFailed
        }
    }

    @State private var restorePromptPresented = false

    private func performRestore() {
        guard let backup = pendingRestore else { return }
        do {
            try manager.restoreBackup(backup)
            dismiss()
        } catch {
            // 恢复失败留在当前页提示，不静默关闭
            errorMessage = strings.providerBackupRestoreFailed
        }
    }
}
