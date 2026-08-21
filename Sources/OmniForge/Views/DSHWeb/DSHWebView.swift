import SwiftUI

// MARK: - DSH Web 服务管理详情页（实用工具内嵌）
//
// 直接观察 DSHWebManager.shared（与 NetworkDiagnosticsView 同构）；
// 主按钮随状态机切换（SPEC §2.2），日志区自动滚动到尾部。

struct DSHWebView: View {
    let strings: Strings
    @ObservedObject private var manager = DSHWebManager.shared
    @State private var serviceAwaitingStopConfirmation: DSHWebService?

    private static let logAnchorID = "dsh-web-log-bottom"
    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            actionRow
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

    // MARK: 状态徽标行

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
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

    private var statusSymbolName: String {
        switch manager.state {
        case .running: return "circle.fill"
        case .starting, .stopping: return "circle.dotted"
        case .stopped: return "circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .running: return .green
        case .starting, .stopping: return .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    // MARK: 操作行

    private var actionRow: some View {
        HStack(spacing: 10) {
            Text(strings.dshWebPort)
                .font(.system(size: 12, weight: .medium))
            TextField(
                strings.dshWebPort,
                value: Binding(
                    get: { manager.configuredPort },
                    set: { manager.setConfiguredPort($0) }
                ),
                formatter: Self.portFormatter
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .disabled(manager.state == .running || manager.state == .starting || manager.state == .stopping)
            primaryButton
            Button(strings.dshWebRefresh) {
                Task { await manager.refreshServices() }
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Text(DSHWebManager.address(for: manager.configuredPort))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: 已发现服务

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.dshWebServicesTitle)
                .font(.system(size: 12, weight: .semibold))

            if manager.services.isEmpty {
                Text(strings.dshWebNoServices)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(manager.services) { service in
                    serviceRow(service)
                }
            }
        }
    }

    private func serviceRow(_ service: DSHWebService) -> some View {
        let ownedByApplication = manager.isOwnedByApplication(service)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.address)
                    .font(.system(size: 11, design: .monospaced))
                Text("PID \(service.pid) · \(ownedByApplication ? strings.dshWebManagedService : strings.dshWebExternalService)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(strings.dshWebOpenBrowser) {
                manager.openInBrowser(service)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            Button(strings.dshWebStop, role: .destructive) {
                if ownedByApplication {
                    Task { await manager.stop(service: service) }
                } else {
                    serviceAwaitingStopConfirmation = service
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch manager.state {
        case .stopped:
            Button(strings.dshWebStart) {
                Task { await manager.start() }
            }
            .buttonStyle(.borderedProminent)
        case .starting:
            Button(strings.dshWebStateStarting) {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .running:
            Button(strings.dshWebStop) {
                Task { await manager.stop() }
            }
            .buttonStyle(.borderedProminent)
        case .stopping:
            Button(strings.dshWebStateStopping) {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .failed:
            Button(strings.dshWebRestart) {
                Task { await manager.restart() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: 日志区

    /// 复制全部日志到剪贴板（保留换行与事件行格式）。
    private func copyLog() {
        let text = manager.logLines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(strings.dshWebLogTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(strings.dshWebCopyLog) {
                    copyLog()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .disabled(manager.logLines.isEmpty)
                Button(strings.dshWebClearLog) {
                    manager.clearLog()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .disabled(manager.logLines.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if manager.logLines.isEmpty {
                            Text(strings.dshWebLogEmpty)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(Array(manager.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            // 滚动锚点：新日志追加后滚到尾部
                            Color.clear
                                .frame(height: 0)
                                .id(Self.logAnchorID)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: manager.logLines.count) { _, _ in
                    guard !manager.logLines.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.logAnchorID, anchor: .bottom)
                    }
                }
            }
            .frame(height: 180)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}
