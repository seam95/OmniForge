import SwiftUI

// MARK: - DSH Web 服务管理详情页（实用工具内嵌）
//
// 直接观察 DSHWebManager.shared（与 NetworkDiagnosticsView 同构）；
// 主按钮随状态机切换（SPEC §2.2），日志区自动滚动到尾部。

struct DSHWebView: View {
    let strings: Strings
    @ObservedObject private var manager = DSHWebManager.shared

    private static let logAnchorID = "dsh-web-log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
            actionRow
            logSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            primaryButton
            Button(strings.dshWebOpenBrowser) {
                manager.openInBrowser()
            }
            .buttonStyle(.bordered)
            .disabled(manager.state != .running)
            Spacer(minLength: 8)
            Text(DSHWebManager.address)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(strings.dshWebLogTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
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
