import SwiftUI

// MARK: - 端口分段：统计 hero + 提示条 + 工具条 + 列表 + 结束进程确认流

struct PortSegmentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let strings: Strings
    @ObservedObject var service: NetworkDiagnosticsService

    private var tint: Color { UtilityTool.networkDiagnostics.tintColor }
    private var text1: Color { colorScheme == .light ? Theme.Stats.text1 : Color.primary }
    private var text2: Color { colorScheme == .light ? Theme.Stats.text2 : Color.secondary }
    private var text3: Color { colorScheme == .light ? Theme.Stats.text3 : Color.secondary }

    @State private var isBannerExpanded = false
    @State private var termConfirmEntry: PortEntry?
    @State private var killConfirmEntry: PortEntry?
    @State private var sudoFailEntry: PortEntry?
    /// Non-nil shows the success/info alert (signal sent, or process already gone).
    @State private var successAlertTitle: String?
    @State private var postTermTask: Task<Void, Never>?

    var body: some View {
        // 平面分区：hero 区自持 h16 v12；横幅/工具条挂内容流；列表行平铺 + separator。
        VStack(alignment: .leading, spacing: 0) {
            if showsHero {
                heroCard
            }

            if showsPermissionBanner {
                permissionBanner
            }

            toolbar
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

    // MARK: Hero

    /// 初次加载中 / 采集失败时不显示 hero，避免展示伪造的 0 统计。
    private var showsHero: Bool {
        if service.permissionHint == .loadFailure { return false }
        return !(service.isRefreshingPorts && service.ports.isEmpty)
    }

    /// 仪表盘 hero：当前 scope 总数为「数字主角」，协议构成比例条 + 图例做构成说明。
    /// 统计基于 scopedPorts（不受搜索词影响），与列表过滤结果解耦。
    private var heroCard: some View {
        let stats = protoStats(from: service.scopedPorts)
        let total = stats.reduce(0) { $0 + $1.count }
        let processCount = Set(service.scopedPorts.map(\.pid).filter { $0 > 0 }).count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                UtilityGlyphTile(symbol: "network", tint: tint, size: 40, symbolSize: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeLabel)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(text1)
                    Text(String(format: strings.networkDiagnosticsProcessCountFormat, processCount))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(text3)
                }

                Spacer(minLength: 8)

                Text("\(total)")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(text1)
            }

            if !stats.isEmpty {
                UtilityProportionBar(
                    segments: stats.map { .init(color: protoTint($0.proto), value: Double($0.count)) },
                    height: 6
                )
                legendRow(stats)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var scopeLabel: String {
        switch service.portScope {
        case .listen:
            return strings.networkDiagnosticsListeningPortsLabel
        case .all:
            return strings.networkDiagnosticsAllConnectionsLabel
        }
    }

    private struct ProtoStat {
        let proto: PortEntry.Proto
        let count: Int
    }

    /// 按固定顺序（TCP / UDP / TCP6 / UDP6）统计协议构成，只保留有数据的段，图例稳定不跳位。
    private func protoStats(from entries: [PortEntry]) -> [ProtoStat] {
        var counts: [PortEntry.Proto: Int] = [:]
        for entry in entries {
            counts[entry.proto, default: 0] += 1
        }
        let order: [PortEntry.Proto] = [.tcp, .udp, .tcp6, .udp6]
        return order.compactMap { proto in
            guard let count = counts[proto], count > 0 else { return nil }
            return ProtoStat(proto: proto, count: count)
        }
    }

    /// 协议配色与卸载器类别条同一家族：Stats 模块色 + teal 补足第四类。
    private func protoTint(_ proto: PortEntry.Proto) -> Color {
        switch proto {
        case .tcp: return Theme.Stats.cpu
        case .udp: return Theme.Stats.ram
        case .tcp6: return Theme.Stats.gpu
        case .udp6: return .teal
        }
    }

    private func legendRow(_ stats: [ProtoStat]) -> some View {
        HStack(spacing: 14) {
            ForEach(stats, id: \.proto) { stat in
                HStack(spacing: 5) {
                    Circle()
                        .fill(protoTint(stat.proto))
                        .frame(width: 6, height: 6)
                    Text(stat.proto.displayName)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(text2)
                    Text("\(stat.count)")
                        .font(Theme.Stats.font10Regular.monospacedDigit())
                        .foregroundStyle(text3)
                }
            }
            Spacer(minLength: 0)
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

            Group {
                if service.isRefreshingPorts {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                } else {
                    IconButton(
                        systemImage: "arrow.clockwise",
                        tint: text2,
                        help: strings.networkDiagnosticsRefresh
                    ) {
                        service.refreshPorts()
                    }
                }
            }
            .accessibilityLabel(strings.networkDiagnosticsRefresh)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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

    /// 权限提示横幅：tint 底（PanelTintBanner）+ 展开后的终端命令 inset 行。
    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTintBanner(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.Stats.ram,
                title: bannerTitle
            ) {
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
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Theme.Stats.cpu)
                }
                .buttonStyle(.borderless)
            }

            if isBannerExpanded {
                HStack(spacing: 8) {
                    Text(NetworkDiagnosticsService.elevatedLsofCommand)
                        .font(Theme.Stats.font10Regular.monospaced())
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
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
                        .font(.system(size: 11))
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(strings.networkDiagnosticsCopyTerminalCommand)
                    .accessibilityLabel(strings.networkDiagnosticsCopyTerminalCommand)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.04))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                // Outer ControlCenter AdaptiveHeightScroll owns scrolling — no nested ScrollView.
                // 行平铺白底，行间 separator 分隔（区别于分区发丝线）。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle()
                                .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                                .frame(height: 1)
                        }
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
