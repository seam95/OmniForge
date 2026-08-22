import SwiftUI

// MARK: - DSH Web 服务管理详情页（实用工具内嵌）
//
// 观察 DSHWebManager.shared；
// 采用「服务控制与实例一体化卡片」+「运行日志终端」的双卡片精美布局。

struct DSHWebView: View {
    let strings: Strings
    @ObservedObject private var manager = DSHWebManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var serviceAwaitingStopConfirmation: DSHWebService?
    @State private var isLogCopied = false
    @State private var isAddressCopied = false

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
            unifiedServiceCard
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

    // MARK: - 统一服务与实例管理卡片

    private var unifiedServiceCard: some View {
        PanelCardChrome(cornerRadius: Theme.Radius.card, padding: 12, accent: statusColor) {
            VStack(alignment: .leading, spacing: 10) {
                // 1. 顶部：标题、状态与主控制按钮
                heroHeaderRow

                // 2. 运行态：高亮地址条与快捷浏览器跳转
                if manager.state == .running {
                    activeAddressBanner
                }

                // 3. 端口配置与辅助操作
                heroBottomRow

                // 4. 已发现实例整合区（如有运行中的实例）
                if !manager.services.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 1)

                    discoveredInstancesSubSection
                }
            }
        }
    }

    // MARK: - 主控区子组件

    private var heroHeaderRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusColor.opacity(colorScheme == .dark ? 0.20 : 0.10))
                    .frame(width: 32, height: 32)

                Image(systemName: statusHeroSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DSH Web")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6.5, height: 6.5)
                        .shadow(color: statusColor.opacity(manager.state == .running ? 0.7 : 0), radius: 2.5)

                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            StatusTintBadge(
                text: statusBadgeText,
                tint: statusColor
            )

            primaryButton
        }
    }

    private var activeAddressBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.green)

            Text(DSHWebManager.address(for: manager.configuredPort))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                copyAddress()
            } label: {
                Image(systemName: isAddressCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: isAddressCopied ? .bold : .regular))
                    .foregroundStyle(isAddressCopied ? .green : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isAddressCopied ? Color.green.opacity(0.15) : Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(.plain)
            .help(isAddressCopied ? "已复制" : strings.dshWebCopyLog)

            Button {
                manager.openInBrowser()
            } label: {
                HStack(spacing: 3) {
                    Text(strings.dshWebOpenBrowser)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.12))
                )
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(strings.dshWebOpenBrowser)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.green.opacity(colorScheme == .dark ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    private var heroBottomRow: some View {
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
                .frame(width: 62)
                .disabled(isBusyOrRunning)

                if manager.configuredPort != DSHWebManager.defaultPort && !isBusyOrRunning {
                    Button {
                        manager.setConfiguredPort(DSHWebManager.defaultPort)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("恢复默认端口 (3080)")
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await manager.refreshServices() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(strings.dshWebRefresh)
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(strings.dshWebRefresh)
        }
    }

    // MARK: - 已发现实例整合列表

    private var discoveredInstancesSubSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(strings.dshWebServicesTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(manager.services.count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                    )

                Spacer(minLength: 0)
            }

            VStack(spacing: 5) {
                ForEach(manager.services) { service in
                    serviceItemRow(service)
                }
            }
        }
    }

    private func serviceItemRow(_ service: DSHWebService) -> some View {
        let ownedByApplication = manager.isOwnedByApplication(service)
        return HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ownedByApplication ? Color.green : Color.accentColor)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((ownedByApplication ? Color.green : Color.accentColor).opacity(colorScheme == .dark ? 0.20 : 0.10))
                )

            VStack(alignment: .leading, spacing: 1.5) {
                Text(service.address)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("PID \(service.pid)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    StatusTintBadge(
                        text: ownedByApplication ? strings.dshWebManagedService : strings.dshWebExternalService,
                        tint: ownedByApplication ? .green : .blue
                    )
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Button {
                    manager.openInBrowser(service)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(strings.dshWebOpenBrowser)

                Button {
                    if ownedByApplication {
                        Task { await manager.stop(service: service) }
                    } else {
                        serviceAwaitingStopConfirmation = service
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.red)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.red.opacity(colorScheme == .dark ? 0.18 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(strings.dshWebStop)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), lineWidth: 1)
        )
    }

    // MARK: - 状态计算与按钮

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

    private var statusBadgeText: String {
        switch manager.state {
        case .stopped:
            return strings.dshWebStateStopped
        case .starting:
            return strings.dshWebStateStarting
        case .running:
            return strings.dshWebStateRunning
        case .stopping:
            return strings.dshWebStateStopping
        case .failed:
            return "异常"
        }
    }

    private var statusHeroSymbol: String {
        switch manager.state {
        case .running:
            return "network"
        case .starting, .stopping:
            return "arrow.triangle.2.circlepath"
        case .stopped:
            return "power"
        case .failed:
            return "exclamationmark.triangle"
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
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .starting:
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(strings.dshWebStateStarting)
                        .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .stopping:
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(strings.dshWebStateStopping)
                        .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - 日志区

    private func copyAddress() {
        let address = DSHWebManager.address(for: manager.configuredPort)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)

        withAnimation(Theme.Animation.snappy) {
            isAddressCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(Theme.Animation.snappy) {
                isAddressCopied = false
            }
        }
    }

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
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(strings.dshWebLogTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if !manager.logLines.isEmpty {
                        Text("\(manager.logLines.count)")
                            .font(.system(size: 9.5, weight: .bold))
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
                    HStack(spacing: 3.5) {
                        Image(systemName: isLogCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: isLogCopied ? .bold : .regular))
                        Text(isLogCopied ? "已复制" : strings.dshWebCopyLog)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(isLogCopied ? .green : Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isLogCopied ? Color.green.opacity(0.12) : Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
                .disabled(manager.logLines.isEmpty)

                Button {
                    manager.clearLog()
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text(strings.dshWebClearLog)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
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
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text(strings.dshWebLogEmpty)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(manager.logLines.enumerated()), id: \.offset) { _, line in
                            logLineView(line)
                        }
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
                .fill(Color.black.opacity(colorScheme == .dark ? 0.38 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 1)
        )
    }

    private func logLineView(_ line: String) -> some View {
        let isAlert = line.contains("SIGKILL") || line.contains("失败") || line.contains("占用") || line.contains("无法") || line.contains("超时") || line.contains("提前退出")
        let isSuccess = line.contains("服务就绪") || line.contains("已启动")
        let isWarning = line.contains("SIGTERM")

        let messageColor: Color = {
            if isAlert { return .red }
            if isSuccess { return .green }
            if isWarning { return .orange }
            return .primary
        }()

        return HStack(alignment: .top, spacing: 6) {
            if let timestampEnd = line.firstIndex(of: "]"), line.hasPrefix("[") {
                let timestamp = String(line[...timestampEnd])
                let message = String(line[line.index(after: timestampEnd)...]).trimmingCharacters(in: .whitespaces)

                Text(timestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text(message)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(messageColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(messageColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }
}
