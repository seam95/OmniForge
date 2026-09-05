import SwiftUI

// MARK: - 网络分段（平面分区）：公网 IP hero + 网卡 / 连接分区
//
// hero 以公网 IP 为「数字主角」，主机名与主接口做身份摘要；明细退到
// 「网卡 / 连接」两分区平铺，行间 separator 分隔（区别于分区发丝线）。
// 所有值整行点击复制，复制后短暂对勾反馈；刷新收进 hero 右上角。

struct NetworkSegmentView: View {
    @Environment(\.colorScheme) private var colorScheme
    let strings: Strings
    @ObservedObject var service: NetworkDiagnosticsService

    /// 刚复制的行 id，用于短暂对勾反馈。
    @State private var copiedRowID: String?
    /// 「其他接口」折叠态。
    @State private var otherInterfacesExpanded = false

    private var unavailable: String { strings.networkDiagnosticsValueUnavailable }
    private var tint: Color { UtilityTool.networkDiagnostics.tintColor }

    private var text1: Color { MonitorOverviewPalette.primary(colorScheme) }
    private var text2: Color { MonitorOverviewPalette.secondary(colorScheme) }
    private var text3: Color { MonitorOverviewPalette.auxiliary(colorScheme) }

    /// 列表行间分隔线。
    private var rowSeparator: some View {
        Rectangle()
            .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let identity = service.networkIdentity {
                heroSection(identity)
                FlatHairline()
                interfacesSection(identity)
                FlatHairline()
                connectionSection(identity)
            } else if service.isRefreshingNetwork {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                emptyState
            }
        }
    }

    // MARK: Hero

    private func heroSection(_ identity: NetworkIdentity) -> some View {
        HStack(spacing: 12) {
            UtilityGlyphTile(symbol: "globe", tint: tint, size: 40, symbolSize: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.hostname.isEmpty ? unavailable : identity.hostname)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(primaryInterfaceSummary(identity))
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            publicIPHeroValue
            refreshButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// hero 右侧大数字：公网 IPv4 优先，IPv6-only 兜底；点击复制，复制后短暂变绿。
    @ViewBuilder
    private var publicIPHeroValue: some View {
        switch service.publicIPState {
        case .idle, .loading:
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 18)
                Text(strings.networkDiagnosticsPublicIPSection)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(text3)
            }
        case let .resolved(ipv4, ipv6):
            let ip = (ipv4?.isEmpty == false ? ipv4 : nil) ?? (ipv6?.isEmpty == false ? ipv6 : nil)
            let highlighted = copiedRowID == "hero-public-ip"
            Button {
                guard let ip else { return }
                service.copy(ip)
                showCopiedFeedback("hero-public-ip")
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ip ?? unavailable)
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(highlighted ? Theme.Stats.statusNormal : text1)
                        // 单行 + 高布局优先级：空间紧张时压缩左侧标题，IP 不换行；
                        // 极端长（IPv6-only）时中间截断兜底。
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(strings.networkDiagnosticsPublicIPSection)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(text3)
                }
                .layoutPriority(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ip == nil)
            .accessibilityLabel("\(strings.networkDiagnosticsPublicIPSection) \(ip ?? unavailable)")
            .help(ip == nil ? "" : strings.networkDiagnosticsCopy)
        }
    }

    private var refreshButton: some View {
        Group {
            if service.isRefreshingNetwork {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 24, height: 24)
            } else {
                IconButton(
                    systemImage: "arrow.clockwise",
                    tint: text2,
                    help: strings.networkDiagnosticsRefresh
                ) {
                    service.refreshNetwork()
                }
            }
        }
        .accessibilityLabel(strings.networkDiagnosticsRefresh)
    }

    /// hero 副标题：默认路由所在接口的「en0 · 192.168.1.5」，无接口信息时退回网关。
    private func primaryInterfaceSummary(_ identity: NetworkIdentity) -> String {
        if let primaryName = identity.defaultRoute.interface,
           let iface = identity.interfaces.first(where: { $0.name == primaryName }) {
            if let ipv4 = iface.ipv4, !ipv4.isEmpty {
                return "\(iface.name) · \(ipv4)"
            }
            return iface.name
        }
        if let first = identity.interfaces.first, let ipv4 = first.ipv4, !ipv4.isEmpty {
            return "\(first.name) · \(ipv4)"
        }
        let route = identity.defaultRoute.copyText
        return route.isEmpty ? unavailable : route
    }

    // MARK: 网卡

    /// 只展示握有全局地址的活跃接口；只有 link-local 地址的隧道 / 直连口折叠进「其他」。
    private func isPrimaryInterface(_ iface: NetworkInterface) -> Bool {
        if let ipv4 = iface.ipv4, !ipv4.isEmpty, !ipv4.hasPrefix("169.254.") { return true }
        if let ipv6 = iface.ipv6, !ipv6.isEmpty, !ipv6.lowercased().hasPrefix("fe80") { return true }
        return false
    }

    @ViewBuilder
    private func interfacesSection(_ identity: NetworkIdentity) -> some View {
        let active = identity.interfaces.filter { iface in
            (iface.ipv4?.isEmpty == false) || (iface.ipv6?.isEmpty == false)
        }
        let primary = active.filter(isPrimaryInterface)
        let others = active.filter { !isPrimaryInterface($0) }

        section(title: strings.networkDiagnosticsInterfacesSection) {
            if active.isEmpty {
                Text(unavailable)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(primary.enumerated()), id: \.element.name) { index, iface in
                    if index > 0 { rowSeparator }
                    interfaceRow(iface)
                }

                if !others.isEmpty {
                    if !primary.isEmpty { rowSeparator }
                    otherInterfacesDisclosure(others)
                    if otherInterfacesExpanded {
                        ForEach(others, id: \.name) { iface in
                            rowSeparator
                            interfaceRow(iface)
                        }
                    }
                }
            }
        }
    }

    /// 「其他 N 个接口」折叠头：只握 link-local 地址的接口默认收起，需要时展开。
    private func otherInterfacesDisclosure(_ others: [NetworkInterface]) -> some View {
        Button {
            withAnimation(Theme.Animation.snappy) { otherInterfacesExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(otherInterfacesExpanded ? 90 : 0))
                Text(String(format: strings.networkDiagnosticsOtherInterfacesFormat, others.count))
                    .font(Theme.Stats.font11Regular)
                Spacer(minLength: 0)
            }
            .foregroundStyle(text2)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func interfaceRow(_ iface: NetworkInterface) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(iface.name)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(text1)
                .padding(.bottom, 2)

            if let ipv4 = iface.ipv4, !ipv4.isEmpty {
                valueRow(
                    id: "iface-\(iface.name)-v4",
                    label: strings.networkDiagnosticsInterfaceIPv4,
                    value: ipv4,
                    copyText: ipv4
                )
            }
            if let ipv6 = iface.ipv6, !ipv6.isEmpty {
                valueRow(
                    id: "iface-\(iface.name)-v6",
                    label: strings.networkDiagnosticsInterfaceIPv6,
                    value: ipv6,
                    copyText: ipv6
                )
            }
            if let mac = iface.mac, !mac.isEmpty {
                valueRow(
                    id: "iface-\(iface.name)-mac",
                    label: strings.networkDiagnosticsInterfaceMAC,
                    value: mac,
                    copyText: mac
                )
            }
            if iface.ipv4 == nil && iface.ipv6 == nil && iface.mac == nil {
                Text(unavailable)
                    .font(Theme.Stats.font11Regular.monospaced())
                    .foregroundStyle(text3)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: 连接（网关 / DNS / 公网 IPv6）

    @ViewBuilder
    private func connectionSection(_ identity: NetworkIdentity) -> some View {
        section(title: strings.networkDiagnosticsConnectionSection) {
            VStack(alignment: .leading, spacing: 0) {
                let route = identity.defaultRoute
                valueRow(
                    id: "route",
                    label: strings.networkDiagnosticsGateway,
                    value: displayRoute(route),
                    copyText: route.copyText
                )

                rowSeparator

                let dnsText = identity.dnsServers.joined(separator: ", ")
                valueRow(
                    id: "dns",
                    label: strings.networkDiagnosticsDNSServers,
                    value: dnsText.isEmpty ? unavailable : dnsText,
                    copyText: dnsText
                )

                rowSeparator

                // 公网 IPv4 已是 hero 主角，这里只补 IPv6；查询中显示占位文案。
                switch service.publicIPState {
                case .idle, .loading:
                    valueRow(
                        id: "public-v6",
                        label: strings.networkDiagnosticsPublicIPv6,
                        value: strings.networkDiagnosticsPublicIPLoading,
                        copyText: ""
                    )
                case let .resolved(_, ipv6):
                    valueRow(
                        id: "public-v6",
                        label: strings.networkDiagnosticsPublicIPv6,
                        value: ipv6 ?? unavailable,
                        copyText: ipv6 ?? ""
                    )
                }
            }
        }
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(strings.networkDiagnosticsNetworkEmpty)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(text3)
            Button(strings.networkDiagnosticsRefresh) {
                service.refreshNetwork()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }

    // MARK: 通用行 / 分区

    /// 平面分区：区头（tint 色块）+ 内容平铺，分区基准内边距 h16 v12。
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: title, accent: tint)
            VStack(spacing: 0) {
                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 轻量复制行：标签 + 等宽值 + 复制 / 对勾图标；空 copyText 时禁用。
    private func valueRow(
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
            HStack(spacing: 8) {
                Text(label)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(text3)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .font(Theme.Stats.font11Regular.monospaced())
                    .foregroundStyle(text1)
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
                            .foregroundStyle(text3)
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
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
