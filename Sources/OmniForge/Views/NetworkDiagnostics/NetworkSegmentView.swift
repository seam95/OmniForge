import SwiftUI

// MARK: - 网络分段：身份卡 + 复制 + 公网 IP 三态

struct NetworkSegmentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let strings: Strings
    @ObservedObject var service: NetworkDiagnosticsService

    /// 刚复制的行 id，用于短暂对勾反馈。
    @State private var copiedRowID: String?

    private var unavailable: String { strings.networkDiagnosticsValueUnavailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar

            if let identity = service.networkIdentity {
                identityCard(identity)
            } else if service.isRefreshingNetwork {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                Text(strings.networkDiagnosticsNetworkEmpty)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                service.refreshNetwork()
            } label: {
                if service.isRefreshingNetwork {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.borderless)
            .help(strings.networkDiagnosticsRefresh)
            .disabled(service.isRefreshingNetwork)
            .accessibilityLabel(strings.networkDiagnosticsRefresh)
        }
    }

    // MARK: Identity card

    @ViewBuilder
    private func identityCard(_ identity: NetworkIdentity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            section(title: strings.networkDiagnosticsHostSection) {
                copyRow(
                    id: "hostname",
                    label: strings.networkDiagnosticsHostname,
                    value: identity.hostname.isEmpty ? unavailable : identity.hostname,
                    copyText: identity.hostname
                )
            }

            section(title: strings.networkDiagnosticsInterfacesSection) {
                if identity.interfaces.isEmpty {
                    Text(unavailable)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                } else {
                    ForEach(Array(identity.interfaces.enumerated()), id: \.offset) { index, iface in
                        interfaceBlock(iface, index: index)
                    }
                }
            }

            section(title: strings.networkDiagnosticsRouteSection) {
                let route = identity.defaultRoute
                let routeCopy = route.copyText
                copyRow(
                    id: "route",
                    label: strings.networkDiagnosticsGateway,
                    value: displayRoute(route),
                    copyText: routeCopy
                )
            }

            section(title: strings.networkDiagnosticsDNSSection) {
                let dnsText = identity.dnsServers.joined(separator: ", ")
                copyRow(
                    id: "dns",
                    label: strings.networkDiagnosticsDNSServers,
                    value: dnsText.isEmpty ? unavailable : dnsText,
                    copyText: dnsText
                )
            }

            section(title: strings.networkDiagnosticsPublicIPSection) {
                publicIPRows
            }
        }
    }

    @ViewBuilder
    private func interfaceBlock(_ iface: NetworkInterface, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(iface.name)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)

            if let ipv4 = iface.ipv4, !ipv4.isEmpty {
                copyRow(
                    id: "iface-\(index)-v4",
                    label: strings.networkDiagnosticsInterfaceIPv4,
                    value: ipv4,
                    copyText: ipv4
                )
            }
            if let ipv6 = iface.ipv6, !ipv6.isEmpty {
                copyRow(
                    id: "iface-\(index)-v6",
                    label: strings.networkDiagnosticsInterfaceIPv6,
                    value: ipv6,
                    copyText: ipv6
                )
            }
            if let mac = iface.mac, !mac.isEmpty {
                copyRow(
                    id: "iface-\(index)-mac",
                    label: strings.networkDiagnosticsInterfaceMAC,
                    value: mac,
                    copyText: mac
                )
            }
            if iface.ipv4 == nil && iface.ipv6 == nil && iface.mac == nil {
                Text(unavailable)
                    .font(Theme.Stats.font11Regular.monospaced())
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var publicIPRows: some View {
        switch service.publicIPState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(strings.networkDiagnosticsPublicIPLoading)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .panelRowCard()
        case let .resolved(ipv4, ipv6):
            copyRow(
                id: "public-v4",
                label: strings.networkDiagnosticsPublicIPv4,
                value: ipv4 ?? unavailable,
                copyText: ipv4 ?? ""
            )
            copyRow(
                id: "public-v6",
                label: strings.networkDiagnosticsPublicIPv6,
                value: ipv6 ?? unavailable,
                copyText: ipv6 ?? ""
            )
        }
    }

    // MARK: Rows

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                .textCase(.uppercase)
            VStack(spacing: 6) {
                content()
            }
        }
    }

    /// 标签 + 值 + 复制按钮；空 copyText 时禁用复制。
    private func copyRow(
        id: String,
        label: String,
        value: String,
        copyText: String
    ) -> some View {
        let canCopy = !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let highlighted = copiedRowID == id
        return Button {
            guard canCopy else { return }
            service.copy(copyText)
            showCopiedFeedback(id)
        } label: {
            HStack(spacing: 10) {
                Text(label)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .font(Theme.Stats.font12Medium.monospaced())
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canCopy {
                    if highlighted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Stats.statusNormal)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .panelRowCard(isInteractive: canCopy)
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(Theme.Stats.statusNormal.opacity(0.4), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canCopy)
        .accessibilityLabel("\(label) \(value)")
        .help(canCopy ? strings.networkDiagnosticsCopy : "")
    }

    private func displayRoute(_ route: DefaultRoute) -> String {
        let text = route.copyText
        return text.isEmpty ? unavailable : text
    }

    private func showCopiedFeedback(_ id: String) {
        withAnimation { copiedRowID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedRowID == id {
                withAnimation { copiedRowID = nil }
            }
        }
    }
}
