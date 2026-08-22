import SwiftUI

/// Overview page: device summary header, 2-column metric cards (network full-width), footer actions.
struct MonitorOverviewView: View {
    let snapshot: SystemSnapshot
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
            temperatureUnit: configuration.temperatureUnit
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
            VStack(alignment: .leading, spacing: 12) {
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
            parts.append(uptime)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(hasIssues ? Color.orange : Color.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill((hasIssues ? Color.orange : Color.green).opacity(0.15))
            )
    }

    // MARK: - Cards

    private var cardRows: some View {
        VStack(spacing: 10) {
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
        switch group {
        case let .metric(model):
            if model.id == .cpu {
                MonitorCPUGaugeCard(
                    model: model,
                    height: height,
                    action: { onSelectRankable(.cpu) }
                )
            } else if model.id == .memory {
                MonitorMemoryDashboardCard(
                    model: model,
                    height: height,
                    action: { onSelectRankable(.memory) }
                )
            } else if model.id == .disk {
                MonitorDiskMetricCard(
                    model: model,
                    strings: strings,
                    height: height,
                    action: { onSelectDiskDetail() }
                )
            } else {
                cardView(for: model, height: height)
            }
        case let .power(battery, energy):
            MonitorPowerMetricCard(
                battery: battery,
                energy: energy,
                height: height,
                onSelectEnergy: { onSelectRankable(.energy) }
            )
        }
    }

    @ViewBuilder
    private func cardView(for model: MonitorCardModel, height: CGFloat? = nil) -> some View {
        let accent = model.progress.map {
            MonitorCardAccent.barTint(for: model.id, progress: $0)
        } ?? MonitorCardAccent.color(for: model.id)

        let action: (() -> Void)? = {
            if model.opensDiskDetail {
                return { onSelectDiskDetail() }
            }
            guard let kind = model.processMetricKind else { return nil }
            return { onSelectRankable(kind) }
        }()

        MonitorMetricCard(
            title: model.title,
            systemImage: model.systemImage,
            primaryText: model.primaryText,
            secondaryText: model.secondaryText,
            progress: model.progress,
            accent: accent,
            badgeText: model.badgeText,
            showsLiveDot: model.showsLiveDot,
            isRankable: model.processMetricKind != nil || model.opensDiskDetail,
            issueText: model.issueText,
            fixedHeight: height,
            action: action
        )
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

            FooterButton(label: strings.monitorRefreshAll, systemImage: "arrow.clockwise") {
                onRefresh()
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}
