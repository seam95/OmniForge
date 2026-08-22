import SwiftUI

/// Overview page: device summary header, 4-row metric cards (CPU|内存 → 网络 → 电池|GPU → 磁盘), footer actions.
struct MonitorOverviewView: View {
    let snapshot: SystemSnapshot
    let history: MetricHistory
    let configuration: MonitorConfiguration
    let strings: Strings
    let deviceSummary: DeviceSummary
    let onSelectRankable: (ProcessMetricKind) -> Void
    let onSelectDiskDetail: () -> Void
    let onOpenSettings: () -> Void
    var showsSettingsAction = true
    let onRefresh: () -> Void

    private var models: [MonitorCardModel] {
        MonitorCardModelBuilder.models(
            snapshot: snapshot,
            configuration: configuration,
            strings: strings,
            temperatureUnit: configuration.temperatureUnit,
            history: history
        )
    }

    private var dashboardRows: [MonitorOverviewRow] {
        MonitorOverviewCardGroup.dashboardRows(from: models)
    }

    private var statusText: String {
        snapshot.issues.isEmpty ? strings.monitorStatusNormal : strings.monitorStatusIssue
    }

    private var hasIssues: Bool {
        !snapshot.issues.isEmpty
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                header
                cardRows
                footer
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // 高度由 MonitorContainerView 固定外壳决定（避免 route 切换时 popover 跳变）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(deviceSummary.hostName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            statusPill
        }
    }

    private var subtitleText: String? {
        var parts: [String] = []
        if let os = deviceSummary.osVersionText, !os.isEmpty {
            parts.append(os)
        }
        if let uptime = deviceSummary.uptimeText, !uptime.isEmpty {
            parts.append("\(strings.monitorUptimePrefix) \(uptime)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hasIssues ? Color.orange : Color.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill((hasIssues ? Color.orange : Color.green).opacity(0.15))
                )

            IconButton(systemImage: "arrow.clockwise", help: strings.monitorRefreshAll) {
                onRefresh()
            }
        }
    }

    // MARK: - Cards

    private var cardRows: some View {
        VStack(spacing: 8) {
            ForEach(dashboardRows) { row in
                rowView(for: row)
                    .frame(height: row.height)
            }
        }
    }

    @ViewBuilder
    private func rowView(for row: MonitorOverviewRow) -> some View {
        switch row {
        case let .single(group, _):
            groupView(for: group, height: row.height)
        case let .pair(left, right, _):
            HStack(alignment: .top, spacing: 10) {
                groupView(for: left, height: row.height)
                    .frame(maxWidth: .infinity)
                groupView(for: right, height: row.height)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func groupView(for group: MonitorOverviewCardGroup, height: CGFloat) -> some View {
        if let model = group.metricModel {
            let accent = MonitorCardAccent.color(for: model.id)

            switch group.displayKind {
            case .cpuTrend:
                MonitorTrendCard(
                    model: model,
                    accent: accent,
                    visualization: .sparkline(model.trend ?? []),
                    height: height,
                    action: { onSelectRankable(.cpu) }
                )
            case .gpuTrend:
                MonitorTrendCard(
                    model: model,
                    accent: accent,
                    visualization: .sparkline(model.trend ?? []),
                    height: height,
                    action: { onSelectRankable(.gpu) }
                )
            case .memoryGauge:
                MonitorTrendCard(
                    model: model,
                    accent: accent,
                    visualization: .semiGauge(progress: model.progress ?? 0),
                    height: height,
                    action: { onSelectRankable(.memory) }
                )
            case .batteryBar:
                MonitorTrendCard(
                    model: model,
                    accent: accent,
                    visualization: .progressBar(progress: model.progress ?? 0),
                    height: height,
                    action: nil
                )
            case .networkDual:
                MonitorNetworkCard(
                    model: model,
                    accent: accent,
                    height: height,
                    action: { onSelectRankable(.network) }
                )
            case .diskChips:
                MonitorDiskMetricCard(
                    model: model,
                    accent: accent,
                    height: height,
                    action: { onSelectDiskDetail() }
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if showsSettingsAction {
                FooterButton(label: strings.monitorPreferences, systemImage: "slider.horizontal.3") {
                    onOpenSettings()
                }
            }

            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}
