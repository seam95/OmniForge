import SwiftUI

/// 风扇详情页：风扇读数区（每风扇 RPM/区间条/目标/模式）→ 温度传感器区（热区分组）
/// → 控制区（性能模式/档位/每风扇手动滑杆，注入协调器时显示）。
/// RPM 趋势折线待监控历史结构（并行改造中）落定后接入。
struct MonitorFanDetailView: View {
    let snapshot: SystemSnapshot
    let strings: Strings
    let temperatureUnit: TemperatureUnit
    let onBack: () -> Void
    let onRefresh: () -> Void
    /// 控制协调器与偏好 — 注入时展示控制区（监控只读路径为 nil）
    var fanControl: FanControlCoordinator? = nil
    var fanPreferences: FanPreferences? = nil

    @Environment(\.colorScheme) private var colorScheme
    /// 已展开的热区（默认全部收起，摘要形态优先）
    @State private var expandedZones: Set<ThermalZone> = []

    private var fans: [FanReading] {
        snapshot.fans
    }

    private var sensorSummaries: [FanSensorGroupSummary] {
        FanSensorGroupSummary.summaries(from: snapshot.sensors)
    }

    private var hiddenUnknownCount: Int {
        FanSensorGroupSummary.hiddenUnknownCount(from: snapshot.sensors)
    }

    var body: some View {
        Group {
            if fans.isEmpty && snapshot.issues[.fan] == nil && snapshot.sensors.isEmpty {
                // 真空态：无风扇也无传感器读数（未采样或异常）
                emptyView
            } else {
                contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // 后台刷新注册状态缓存（SMAppService.status 是同步 XPC，
            // 禁止在主线程直查 — 会连带冻结主 runloop 上的全局事件 tap）
            fanControl?.refreshHelperRegistration()
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 12) {
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
    }

    // MARK: - Content

    private var contentView: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    fansSection
                    // 全 unknown 时摘要为空，但仍需展示区标题与隐藏计数保持信息透明
                    if !sensorSummaries.isEmpty || hiddenUnknownCount > 0 {
                        Divider()
                            .overlay(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                        sensorsSection
                    }
                    if fanControl?.hasFans == true, fanPreferences != nil {
                        Divider()
                            .overlay(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
                        controlSection
                    }
                }
                .padding(12)
            }
        }
    }

    private var header: some View {
        FlatBackBar(title: strings.fanDetailTitle, backLabel: strings.commonBack, onBack: onBack) {
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
            } else if fans.isEmpty, !snapshot.sensors.isEmpty {
                // 无风扇机型：读数区让位给一句说明，传感器区仍完整展示
                Label(strings.fanNoFans, systemImage: "fanblades.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(strings.fanSensorSectionTitle)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))

            ForEach(sensorSummaries, id: \.zone) { summary in
                sensorGroup(summary)
            }

            if hiddenUnknownCount > 0 {
                Text(String(format: strings.fanSensorHiddenCountFormat, hiddenUnknownCount))
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
        }
        .padding(.vertical, 4)
    }

    /// 热区分组：摘要行（组名 + 热点 + 最高温）点击展开单列明细；单传感器组直显不折叠
    @ViewBuilder
    private func sensorGroup(_ summary: FanSensorGroupSummary) -> some View {
        let expandable = summary.sensors.count > 1
        let isExpanded = expandedZones.contains(summary.zone)

        VStack(alignment: .leading, spacing: 6) {
            if expandable {
                Button {
                    withAnimation(Theme.Animation.pageTransition) {
                        if isExpanded {
                            expandedZones.remove(summary.zone)
                        } else {
                            expandedZones.insert(summary.zone)
                        }
                    }
                } label: {
                    summaryRow(summary, chevronVisible: true, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
            } else {
                summaryRow(summary, chevronVisible: false, isExpanded: false)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.sensors) { sensor in
                        sensorCell(sensor, isHottest: sensor.id == summary.hottest?.id)
                    }
                }
            }
        }
    }

    /// 摘要行：组名 + 热点传感器名（单传感器组直接显示该读数名）+ 组内最高温
    private func summaryRow(
        _ summary: FanSensorGroupSummary,
        chevronVisible: Bool,
        isExpanded: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if chevronVisible {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(zoneName(summary.zone))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                if let hottest = summary.hottest {
                    Text(summary.sensors.count > 1
                        ? String(format: strings.fanSensorHottestFormat, hottest.label)
                        : hottest.label
                    )
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let hottest = summary.hottest {
                Text(MetricFormat.temperature(hottest.temperatureCelsius, unit: temperatureUnit) ?? "--")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private func zoneName(_ zone: ThermalZone) -> String {
        strings.fanZoneName(zone)
    }

    private func sensorCell(_ sensor: FanSensorReading, isHottest: Bool) -> some View {
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
            HStack(alignment: .center, spacing: 6) {
                if isHottest {
                    Text(strings.fanSensorHottestBadge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MonitorCardAccent.color(for: .fan))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(MonitorOverviewPalette.pillBackground(colorScheme))
                        )
                }
                Text(MetricFormat.temperature(sensor.temperatureCelsius, unit: temperatureUnit) ?? "--")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isHottest
                        ? MonitorCardAccent.color(for: .fan)
                        : MonitorOverviewPalette.primary(colorScheme))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
    }

    // MARK: - 控制区

    @ViewBuilder
    private var controlSection: some View {
        if let fanControl, let fanPreferences {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.fanControlSectionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))

                FanControlGateView(
                    control: fanControl,
                    preferences: fanPreferences,
                    fans: fans,
                    strings: strings,
                    fanNameProvider: fanName
                )
            }
            .padding(.vertical, 4)
        }
    }
}

/// 控制区门禁与内容 — 独立子视图以 @ObservedObject 观察协调器，
/// 注册状态（后台解析的缓存）变化时自动重绘，安装动作后触发刷新
private struct FanControlGateView: View {
    @ObservedObject var control: FanControlCoordinator
    let preferences: FanPreferences
    let fans: [FanReading]
    let strings: Strings
    let fanNameProvider: (FanReading) -> String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !control.helperRegistered {
            helperInstallBanner
        } else {
            performanceControls
            manualSliders
        }
    }

    /// 未安装 Helper：引导安装（首次开启控制的授权入口，SPEC 决策 4）
    private var helperInstallBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings.fanInstallHelperBanner)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                installHelper()
            } label: {
                Text(strings.fanSettingsHelperInstall)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(MonitorOverviewPalette.pillBackground(colorScheme))
        )
    }

    private func installHelper() {
        do {
            try FanHelperInstaller.register()
            // daemon 拉起需短暂时间，异步刷新协调器缓存后本视图经观察自动重绘
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                control.refreshHelperRegistration()
            }
        } catch {
            // 授权取消/失败：保持引导态，错误经 FanSettingsView 可查详情
        }
    }

    private var performanceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(strings.fanPerformanceMode, isOn: Binding(
                get: { preferences.configuration.performanceMode },
                set: { enabled in
                    preferences.update { $0.performanceMode = enabled }
                }
            ))

            if preferences.configuration.performanceMode {
                Picker(strings.fanLevelLabel, selection: Binding(
                    get: { preferences.configuration.performanceLevel },
                    set: { level in
                        preferences.update { $0.performanceLevel = level }
                    }
                )) {
                    Text(strings.fanLevelLow).tag(FanCurve.Level.low)
                    Text(strings.fanLevelMedium).tag(FanCurve.Level.medium)
                    Text(strings.fanLevelHigh).tag(FanCurve.Level.high)
                    Text(strings.fanLevelMax).tag(FanCurve.Level.max)
                }
                .pickerStyle(.segmented)

                if control.batterySaverSuppressed {
                    Text(strings.fanBatterySaverNotice)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(Theme.Stats.ram)
                }
                if let error = control.lastError {
                    Text(error)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(Theme.Stats.up)
                        .lineLimit(2)
                }
            }

            Button(strings.fanResetAllButton, action: { control.handBackToAuto() })
                .controlSize(.small)
        }
    }

    private var manualSliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fans) { fan in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(fanNameProvider(fan))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        Spacer()
                        if let target = control.currentManualTargets[fan.id] {
                            Text("\(MetricFormat.rpm(target) ?? "--") RPM")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(MonitorCardAccent.color(for: .fan))
                            Button(strings.fanAutoButton) {
                                control.clearManualTarget(index: fan.id)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderless)
                        }
                    }
                    Slider(
                        value: Binding(
                            get: { control.currentManualTargets[fan.id] ?? fan.currentRPM },
                            set: { newValue in
                                control.setManualTarget(index: fan.id, rpm: newValue)
                            }
                        ),
                        in: fan.minRPM...fan.maxRPM,
                        step: 100
                    )
                    .tint(MonitorCardAccent.color(for: .fan))
                }
            }
        }
    }
}
