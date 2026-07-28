import SwiftUI

// MARK: - 端口列表单行：字段 + 右键 / 行尾菜单

struct PortRowView: View {
    let entry: PortEntry
    let processName: String
    let canTerminate: Bool
    let strings: Strings
    let onCopy: (String) -> Void
    let onTerminate: () -> Void

    private var unavailable: String { strings.networkDiagnosticsValueUnavailable }

    private var displayProcessName: String {
        let trimmed = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? strings.networkDiagnosticsUnknownProcess : trimmed
    }

    private var processLabel: String {
        if entry.pid > 0 {
            return String(
                format: strings.networkDiagnosticsProcessPIDFormat,
                displayProcessName,
                entry.pid
            )
        }
        return displayProcessName
    }

    private var stateLabel: String {
        let raw = entry.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? unavailable : raw
    }

    private var stateTint: Color {
        let normalized = stateLabel.uppercased()
        if normalized == "LISTEN" || normalized == "LISTENING" {
            return .green
        }
        if normalized == unavailable.uppercased() {
            return .secondary
        }
        return Color.secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.proto.displayName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            Text(entry.localPortDisplay)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 52, alignment: .leading)
                .help(entry.hostPortCopyText)

            Text(processLabel)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(processLabel)

            StatusTintBadge(text: stateLabel, tint: stateTint)
                .frame(width: 72, alignment: .trailing)

            trailingMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .panelRowCard(isInteractive: true)
        .contextMenu { menuActions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.proto.displayName) \(entry.localPortDisplay) \(processLabel) \(stateLabel)"
        )
    }

    // MARK: Menus

    private var trailingMenu: some View {
        Menu {
            menuActions
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help(strings.networkDiagnosticsCopy)
    }

    @ViewBuilder
    private var menuActions: some View {
        Button(strings.networkDiagnosticsCopyHostPort) {
            onCopy(entry.hostPortCopyText)
        }
        Button(strings.networkDiagnosticsCopyPID) {
            guard entry.pid > 0 else { return }
            onCopy(String(entry.pid))
        }
        .disabled(entry.pid <= 0)

        Button(strings.networkDiagnosticsCopyProcessName) {
            onCopy(displayProcessName)
        }

        Button(strings.networkDiagnosticsCopySudoKill) {
            guard entry.pid > 0 else { return }
            onCopy(ProcessTerminator.sudoKillCommand(pid: entry.pid))
        }
        .disabled(entry.pid <= 0)

        Divider()

        if canTerminate {
            Button(strings.networkDiagnosticsTerminateProcess, role: .destructive) {
                onTerminate()
            }
        } else {
            Button(strings.networkDiagnosticsProtectedProcess) {}
                .disabled(true)
        }
    }
}
