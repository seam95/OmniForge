import SwiftUI

/// 恢复备份列表（SPEC 2.5）：展示目标工具的历史快照，手动恢复前二次确认。
struct BackupRestoreView: View {
    @ObservedObject var manager: ProviderSwitchManager
    let strings: Strings
    let tool: ProviderTool

    @Environment(\.dismiss) private var dismiss
    @State private var pendingRestore: ProviderBackup?
    @State private var errorMessage: String?

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
                        Button(strings.providerBackupRestore) {
                            pendingRestore = backup
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
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
        .frame(width: 460, height: 380)
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
