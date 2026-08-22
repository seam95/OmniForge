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

    @Environment(\.colorScheme) private var colorScheme

    private var stateTint: Color {
        let normalized = stateLabel.uppercased()
        if normalized == "LISTEN" || normalized == "LISTENING" {
            return Theme.Stats.statusNormal
        }
        if normalized == unavailable.uppercased() {
            return colorScheme == .light ? Theme.Stats.text3 : Color.secondary
        }
        return colorScheme == .light ? Theme.Stats.text3 : Color.secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(displayProcessName)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayProcessName)

                Spacer(minLength: 4)

                StatusTintBadge(text: stateLabel, tint: stateTint)

                trailingMenu
            }

            HStack(spacing: 6) {
                Text(entry.proto.displayName)
                    .font(Theme.Stats.font10Regular.monospaced())
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.08))
                    )

                Text(":\(entry.localPortDisplay)")
                    .font(Theme.Stats.font11Regular.monospacedDigit())
                    .foregroundStyle(Theme.Stats.cpu)
                    .help(entry.hostPortCopyText)

                if entry.pid > 0 {
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)

                    Text("PID \(entry.pid)")
                        .font(Theme.Stats.font10Regular.monospaced())
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                }

                Spacer(minLength: 0)
            }
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
