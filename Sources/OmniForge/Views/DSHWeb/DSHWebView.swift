import SwiftUI

// MARK: - DSH Web 服务管理详情页（实用工具内嵌）
//
// 观察 DSHWebManager.shared；
// 采用主服务控制卡片、已发现服务卡片列表与控制台日志区的三段式布局。

struct DSHWebView: View {
    let strings: Strings
    @ObservedObject private var manager = DSHWebManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var serviceAwaitingStopConfirmation: DSHWebService?
    @State private var isLogCopied = false

    private static let logAnchorID = "dsh-web-log-bottom"
    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        return formatter
    }()

    private var isBusyOrRunning: Bool {
        manager.state == .running || manager.state == .starting || manager.state == .stopping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            primaryControlCard
            servicesSection
            logSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .task {
            while !Task.isCancelled {
                await manager.refreshServices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert(
            strings.dshWebStopExternalTitle,
            isPresented: Binding(
                get: { serviceAwaitingStopConfirmation != nil },
                set: { if !$0 { serviceAwaitingStopConfirmation = nil } }
            ),
            presenting: serviceAwaitingStopConfirmation
        ) { service in
            Button(strings.dshWebStop, role: .destructive) {
                Task { await manager.stop(service: service) }
                serviceAwaitingStopConfirmation = nil
            }
            Button(strings.dshWebCancel, role: .cancel) {
                serviceAwaitingStopConfirmation = nil
            }
        } message: { service in
            Text(String(
                format: strings.dshWebStopExternalMessageFormat,
                Int(service.pid),
                Int(service.port)
            ))
        }
    }

    // MARK: - 主服务控制卡片

    private var primaryControlCard: some View {
        PanelCardChrome(cornerRadius: Theme.Radius.card, padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                // 上层：状态指示与访问地址
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: statusColor.opacity(manager.state == .running ? 0.6 : 0), radius: 3)
                        Text(statusText)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        Text(DSHWebManager.address(for: manager.configuredPort))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if manager.state == .running {
                            Button {
                                manager.openInBrowser()
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help(strings.dshWebOpenBrowser)
                        }
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                // 下层：端口设置与主控制操作
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(strings.dshWebPort)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(
                            strings.dshWebPort,
                            value: Binding(
                                get: { manager.configuredPort },
                                set: { manager.setConfiguredPort($0) }
                            ),
                            formatter: Self.portFormatter
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 64)
                        .disabled(isBusyOrRunning)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Button {
                            Task { await manager.refreshServices() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(strings.dshWebRefresh)

                        primaryButton
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch manager.state {
        case .stopped:
            return strings.dshWebStateStopped
        case .starting:
            return strings.dshWebStateStarting
        case .running:
            return strings.dshWebStateRunning
        case .stopping:
            return strings.dshWebStateStopping
        case .failed(let reason):
            return String(format: strings.dshWebStateFailed, reason)
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch manager.state {
        case .stopped:
            Button {
                Task { await manager.start() }
            } label: {
                Label(strings.dshWebStart, systemImage: "play.fill")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .starting:
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(strings.dshWebStateStarting)
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(true)
        case .running:
            Button(role: .destructive) {
                Task { await manager.stop() }
            } label: {
                Label(strings.dshWebStop, systemImage: "stop.fill")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .stopping:
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(strings.dshWebStateStopping)
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(true)
        case .failed:
            Button {
                Task { await manager.restart() }
            } label: {
                Label(strings.dshWebRestart, systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - 已发现服务

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(strings.dshWebServicesTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if !manager.services.isEmpty {
                    Text("\(manager.services.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
            }

            if manager.services.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text(strings.dshWebNoServices)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .panelRowCard()
            } else {
                VStack(spacing: 6) {
                    ForEach(manager.services) { service in
                        serviceRow(service)
                    }
                }
            }
        }
    }

    private func serviceRow(_ service: DSHWebService) -> some View {
        let ownedByApplication = manager.isOwnedByApplication(service)
        return HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ownedByApplication ? Color.green : Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((ownedByApplication ? Color.green : Color.accentColor).opacity(colorScheme == .dark ? 0.20 : 0.10))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(service.address)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("PID \(service.pid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    StatusTintBadge(
                        text: ownedByApplication ? strings.dshWebManagedService : strings.dshWebExternalService,
                        tint: ownedByApplication ? .green : .blue
                    )
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    manager.openInBrowser(service)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(strings.dshWebOpenBrowser)
                .frame(width: 24, height: 24)

                Button {
                    if ownedByApplication {
                        Task { await manager.stop(service: service) }
                    } else {
                        serviceAwaitingStopConfirmation = service
                    }
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red)
                .help(strings.dshWebStop)
                .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .panelRowCard(isInteractive: true)
    }

    // MARK: - 日志区

    /// 复制全部日志到剪贴板（保留换行与事件行格式）。
    private func copyLog() {
        let text = manager.logLines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        withAnimation(Theme.Animation.snappy) {
            isLogCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(Theme.Animation.snappy) {
                isLogCopied = false
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(strings.dshWebLogTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if !manager.logLines.isEmpty {
                        Text("\(manager.logLines.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                }

                Spacer(minLength: 0)

                Button {
                    copyLog()
                } label: {
                    HStack(spacing: 4) {
                        if isLogCopied {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        Text(strings.dshWebCopyLog)
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isLogCopied ? .green : Color.accentColor)
                .disabled(manager.logLines.isEmpty)

                Button {
                    manager.clearLog()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text(strings.dshWebClearLog)
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(manager.logLines.isEmpty)
            }

            logConsoleView
        }
    }

    @ViewBuilder
    private var logConsoleView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if manager.logLines.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text(strings.dshWebLogEmpty)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(manager.logLines.enumerated()), id: \.offset) { _, line in
                            logLineView(line)
                        }
                        // 滚动锚点：新日志追加后滚到尾部
                        Color.clear
                            .frame(height: 0)
                            .id(Self.logAnchorID)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .onChange(of: manager.logLines.count) { _, _ in
                guard !manager.logLines.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.logAnchorID, anchor: .bottom)
                }
            }
        }
        .frame(height: 160)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 1)
        )
    }

    private func logLineView(_ line: String) -> some View {
        let isAlert = line.contains("SIGKILL") || line.contains("失败") || line.contains("占用") || line.contains("无法") || line.contains("超时")
        let isSuccess = line.contains("服务就绪")
        let tint: Color = isAlert ? .red : (isSuccess ? .green : .primary)

        return Text(line)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
