import SwiftUI

// MARK: - 端口分段：工具条 + 提示条 + 列表 + 结束进程确认流

struct PortSegmentView: View {
    let strings: Strings
    @ObservedObject var service: NetworkDiagnosticsService

    @State private var isBannerExpanded = false
    @State private var termConfirmEntry: PortEntry?
    @State private var killConfirmEntry: PortEntry?
    @State private var sudoFailEntry: PortEntry?
    /// Non-nil shows the success/info alert (signal sent, or process already gone).
    @State private var successAlertTitle: String?
    @State private var postTermTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar

            if showsPermissionBanner {
                permissionBanner
            }

            content
        }
        .alert(
            strings.networkDiagnosticsTerminateTitle,
            isPresented: termConfirmPresented
        ) {
            Button(strings.networkDiagnosticsTerminateCancel, role: .cancel) {
                termConfirmEntry = nil
            }
            Button(strings.networkDiagnosticsTerminateConfirm, role: .destructive) {
                if let entry = termConfirmEntry {
                    termConfirmEntry = nil
                    performTerminate(entry, signal: .term)
                }
            }
        } message: {
            Text(termConfirmMessage)
        }
        .alert(
            strings.networkDiagnosticsForceTerminateTitle,
            isPresented: killConfirmPresented
        ) {
            Button(strings.networkDiagnosticsTerminateCancel, role: .cancel) {
                killConfirmEntry = nil
            }
            Button(strings.networkDiagnosticsForceTerminateConfirm, role: .destructive) {
                if let entry = killConfirmEntry {
                    killConfirmEntry = nil
                    performTerminate(entry, signal: .kill)
                }
            }
        } message: {
            Text(strings.networkDiagnosticsForceTerminateMessage)
        }
        .alert(
            strings.networkDiagnosticsTerminateFailed,
            isPresented: sudoFailPresented
        ) {
            Button(strings.networkDiagnosticsTerminateCancel, role: .cancel) {
                sudoFailEntry = nil
            }
            Button(strings.networkDiagnosticsCopySudoKill9) {
                if let entry = sudoFailEntry, entry.pid > 0 {
                    service.copy(ProcessTerminator.sudoKill9Command(pid: entry.pid))
                }
                sudoFailEntry = nil
            }
        } message: {
            Text(sudoFailMessage)
        }
        .alert(
            successAlertTitle ?? strings.networkDiagnosticsTerminateSuccess,
            isPresented: successAlertPresented
        ) {
            Button(strings.networkDiagnosticsAlertOK, role: .cancel) {
                successAlertTitle = nil
            }
        }
        .onDisappear {
            postTermTask?.cancel()
            postTermTask = nil
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            PanelSearchField(
                placeholder: strings.networkDiagnosticsSearchPlaceholder,
                text: $service.searchText
            )
            .frame(maxWidth: .infinity)

            PanelFilterCapsules(
                options: [
                    .init(tag: PortScope.listen, title: strings.networkDiagnosticsScopeListen),
                    .init(tag: PortScope.all, title: strings.networkDiagnosticsScopeAll)
                ],
                selection: $service.portScope
            )

            Button {
                service.refreshPorts()
            } label: {
                if service.isRefreshingPorts {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help(strings.networkDiagnosticsRefresh)
            .disabled(service.isRefreshingPorts)
            .accessibilityLabel(strings.networkDiagnosticsRefresh)
        }
    }

    // MARK: Banner

    private var showsPermissionBanner: Bool {
        switch service.permissionHint {
        case .none:
            return false
        case .partialPermission, .loadFailure:
            return true
        }
    }

    private var bannerTitle: String {
        switch service.permissionHint {
        case .loadFailure:
            return strings.networkDiagnosticsPortsLoadFailedBanner
        case .partialPermission, .none:
            return strings.networkDiagnosticsPartialPermissionBanner
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(bannerTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isBannerExpanded.toggle()
                    }
                } label: {
                    Text(
                        isBannerExpanded
                            ? strings.networkDiagnosticsHideCommand
                            : strings.networkDiagnosticsShowCommand
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
            }

            if isBannerExpanded {
                HStack(spacing: 8) {
                    Text(NetworkDiagnosticsService.elevatedLsofCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    Button {
                        service.copy(NetworkDiagnosticsService.elevatedLsofCommand)
                    } label: {
                        Label(
                            strings.networkDiagnosticsCopyTerminalCommand,
                            systemImage: "doc.on.doc"
                        )
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help(strings.networkDiagnosticsCopyTerminalCommand)
                    .accessibilityLabel(strings.networkDiagnosticsCopyTerminalCommand)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .onChange(of: service.permissionHint) { _, newValue in
            if newValue == .none {
                isBannerExpanded = false
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if service.isRefreshingPorts && service.ports.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
        } else {
            let rows = service.filteredPorts
            if rows.isEmpty {
                Text(emptyStateText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                // Outer ControlCenter AdaptiveHeightScroll owns scrolling — no nested ScrollView.
                VStack(alignment: .leading, spacing: 8) {
                    columnHeader
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(rows) { entry in
                            PortRowView(
                                entry: entry,
                                processName: service.processDisplayName(for: entry),
                                canTerminate: service.canTerminate(entry),
                                strings: strings,
                                onCopy: { service.copy($0) },
                                onTerminate: {
                                    requestTerminate(entry)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(strings.networkDiagnosticsColumnProtocol)
                .frame(width: 40, alignment: .leading)
            Text(strings.networkDiagnosticsColumnLocalPort)
                .frame(width: 52, alignment: .leading)
            Text(strings.networkDiagnosticsColumnProcess)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(strings.networkDiagnosticsColumnStatus)
                .frame(width: 72, alignment: .trailing)
            Color.clear.frame(width: 22)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var emptyStateText: String {
        if service.permissionHint == .loadFailure {
            return strings.networkDiagnosticsPortsLoadFailed
        }
        let query = service.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return strings.networkDiagnosticsPortsEmpty
        }
        switch service.portScope {
        case .listen:
            return strings.networkDiagnosticsPortsEmptyListen
        case .all:
            return strings.networkDiagnosticsPortsEmpty
        }
    }

    // MARK: Terminate flow

    private func requestTerminate(_ entry: PortEntry) {
        // 黑名单 / 非法 PID：硬拦，不进确认框。
        guard service.canTerminate(entry) else { return }
        termConfirmEntry = entry
    }

    private func performTerminate(_ entry: PortEntry, signal: TerminationSignal) {
        let result = service.terminate(entry, signal: signal)
        switch result {
        case .success:
            successAlertTitle = strings.networkDiagnosticsTerminateSuccess
            scheduleRefreshAfterSuccess()
        case let .failure(error):
            switch signal {
            case .term:
                if ProcessTerminator.shouldOfferForceKill(after: error) {
                    killConfirmEntry = entry
                }
            case .kill:
                // ESRCH: process already gone — inform user and refresh (not silent).
                if case .notFound = error {
                    successAlertTitle = strings.networkDiagnosticsProcessGone
                    scheduleRefreshAfterSuccess()
                } else if ProcessTerminator.shouldOfferSudoKill9(after: error) {
                    sudoFailEntry = entry
                }
            }
        }
    }

    /// SIGTERM/SIGKILL 成功后约 1.5s 再刷新，给进程退出窗口。
    private func scheduleRefreshAfterSuccess() {
        postTermTask?.cancel()
        postTermTask = Task { @MainActor in
            let delay = ProcessTerminator.postTermRefreshDelay
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            service.refreshPorts()
        }
    }

    private var termConfirmPresented: Binding<Bool> {
        Binding(
            get: { termConfirmEntry != nil },
            set: { if !$0 { termConfirmEntry = nil } }
        )
    }

    private var killConfirmPresented: Binding<Bool> {
        Binding(
            get: { killConfirmEntry != nil },
            set: { if !$0 { killConfirmEntry = nil } }
        )
    }

    private var sudoFailPresented: Binding<Bool> {
        Binding(
            get: { sudoFailEntry != nil },
            set: { if !$0 { sudoFailEntry = nil } }
        )
    }

    private var successAlertPresented: Binding<Bool> {
        Binding(
            get: { successAlertTitle != nil },
            set: { if !$0 { successAlertTitle = nil } }
        )
    }

    private var termConfirmMessage: String {
        guard let entry = termConfirmEntry else { return "" }
        let name = service.processDisplayName(for: entry)
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? strings.networkDiagnosticsUnknownProcess
            : name
        return String(
            format: strings.networkDiagnosticsTerminateMessageFormat,
            display,
            entry.pid,
            entry.localPort
        )
    }

    private var sudoFailMessage: String {
        guard let entry = sudoFailEntry, entry.pid > 0 else {
            return strings.networkDiagnosticsTerminateFailed
        }
        let cmd = ProcessTerminator.sudoKill9Command(pid: entry.pid)
        return "\(strings.networkDiagnosticsTerminateFailed)\n\(cmd)"
    }
}
