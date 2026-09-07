import SwiftUI

/// 风扇详情页：风扇读数区（每风扇 RPM/区间条/目标/模式）→ 温度传感器区（热区分组）。
/// RPM 趋势折线待监控历史结构（并行改造中）落定后接入；控制区（性能模式/手动
/// 调速）随特权 Helper 接入后续阶段并入本页。
struct MonitorFanDetailView: View {
    let snapshot: SystemSnapshot
    let strings: Strings
    let temperatureUnit: TemperatureUnit
    let onBack: () -> Void
    let onRefresh: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var fans: [FanReading] {
        snapshot.fans
    }

    private var groupedSensors: [(zone: ThermalZone, sensors: [FanSensorReading])] {
        let grouped = Dictionary(grouping: snapshot.sensors, by: \.zone)
        return ThermalZone.allCases.compactMap { zone in
            guard let items = grouped[zone], !items.isEmpty else { return nil }
            return (zone, items)
        }
    }

    var body: some View {
        Group {
            if fans.isEmpty && snapshot.issues[.fan] == nil {
                emptyView
            } else {
                contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            header
            Spacer()
            Image(systemName: "fanblades")
                .font(.system(size: 28))
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            Text(strings.fanNoFans)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .font(Theme.Stats.font13SemiBold)
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                    .overlay(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                fansSection
                if !groupedSensors.isEmpty {
                    Divider()
                        .overlay(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                    sensorsSection
                }
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(strings.fanDetailTitle)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            IconButton(systemImage: "arrow.clockwise", help: strings.monitorRefreshAll) {
                onRefresh()
            }
        }
    }

    // MARK: - 风扇区

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let issue = snapshot.issues[.fan] {
                Text(issueText(issue))
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Theme.Stats.up)
            }
            ForEach(fans) { fan in
                fanRow(fan)
            }
        }
        .padding(.vertical, 4)
    }

    /// 风扇展示名：单风扇无名；双风扇 0=左 1=右；更多按序号
    private func fanName(_ fan: FanReading) -> String {
        if fans.count == 1 { return strings.fanNameSingle }
        if fans.count == 2 {
            return fan.id == 0 ? strings.fanNameLeft : strings.fanNameRight
        }
        return String(format: strings.fanNameIndexed, fan.id + 1)
    }

    private func issueText(_ issue: MetricIssue) -> String {
        switch issue {
        case .unsupported: return strings.monitorIssueUnsupported
        case .failed: return strings.monitorIssueFailed
        }
    }

    @ViewBuilder
    private func fanRow(_ fan: FanReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(fanName(fan))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))

                if fan.isManualModeValid, fan.isManualMode {
                    Text(strings.fanModeManualBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(MonitorOverviewPalette.pillBackground(colorScheme))
                        )
                }

                Spacer(minLength: 8)

                // 目标转速（手动模式下与当前差异是常态，只作小字辅助）
                if fan.targetRPMValid, let target = MetricFormat.rpm(fan.targetRPM) {
                    Text("\(strings.fanTargetRPM) \(target)")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fan.currentRPMValid ? (MetricFormat.rpm(fan.currentRPM) ?? "--") : "--")
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                Text("RPM")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
            }

            // 当前转速在硬件 min–max 区间的占比条（固定风扇色，无阈值换色）
            MetricBar(
                value: fan.speedFraction,
                warning: .infinity,
                critical: .infinity,
                tint: MonitorCardAccent.color(for: .fan)
            )
            .frame(height: 4)

            let rangeLow = MetricFormat.rpm(fan.minRPM) ?? "--"
            let rangeHigh = MetricFormat.rpm(fan.maxRPM) ?? "--"
            Text("\(rangeLow) – \(rangeHigh) RPM")
                .font(Theme.Stats.font10Regular.monospacedDigit())
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 传感器区

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.fanSensorSectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))

            ForEach(groupedSensors, id: \.zone) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(zoneName(group.zone))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))

                    let columns = [GridItem(.adaptive(minimum: 150), spacing: 6)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(group.sensors) { sensor in
                            sensorCell(sensor)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func zoneName(_ zone: ThermalZone) -> String {
        switch zone {
        case .cpu: return strings.fanZoneCpu
        case .gpu: return strings.fanZoneGpu
        case .memory: return strings.fanZoneMemory
        case .ssd: return strings.fanZoneSsd
        case .powerDelivery: return strings.fanZonePowerDelivery
        case .battery: return strings.fanZoneBattery
        case .ambient: return strings.fanZoneAmbient
        case .unknown: return strings.fanZoneUnknown
        }
    }

    private func sensorCell(_ sensor: FanSensorReading) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .lineLimit(1)
                if sensor.label != sensor.id {
                    Text(sensor.id)
                        .font(.system(size: 9, weight: .regular).monospacedDigit())
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
            }
            Spacer(minLength: 4)
            Text(MetricFormat.temperature(sensor.temperatureCelsius, unit: temperatureUnit) ?? "--")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
    }
}
