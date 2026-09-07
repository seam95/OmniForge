import SwiftUI

/// 磁盘详情页（平面分区布局）：选盘 → 使用 → 实时活动 → SMART → 保护 → 工具。
/// 对齐 SPEC §3.3–3.9，无编辑排序（区别于 vorssaint）。
/// 风格对齐监控平面语言：无卡片，FlatSectionHeader + 发丝线分区。
struct MonitorDiskDetailView: View {
    let snapshot: SystemSnapshot
    let strings: Strings
    let temperatureUnit: TemperatureUnit
    @ObservedObject var protection: DiskProtectionService
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    var showsSettingsAction: Bool
    let onRefresh: () -> Void

    @State private var selectedDiskID: String?

    private var disks: [PhysicalDiskReading] {
        snapshot.disk?.physicalDisks ?? []
    }

    private var selected: PhysicalDiskReading? {
        guard let id = selectedDiskID else { return disks.first }
        return disks.first(where: { $0.id == id }) ?? disks.first
    }

    /// 磁盘分区统一强调色（与监控 overview 磁盘卡同源）
    private var diskAccent: Color {
        MonitorCardAccent.color(for: .disk)
    }

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Body

    var body: some View {
        Group {
            if disks.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: ensureSelectedDisk)
        .onChange(of: disks.map(\.id)) { _, _ in ensureSelectedDisk() }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "internaldrive")
                    .font(.system(size: 28))
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                Text(strings.diskNoDisks)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .font(Theme.Stats.font13SemiBold)
                Spacer()
                footer
            }
            .padding(12)
        }
    }

    // MARK: - Content

    private var contentView: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    diskSelector
                    hairline
                    if let sel = selected {
                        usageSection(sel)
                        hairline
                        activitySection(sel)
                        hairline
                        smartSection(sel)
                        hairline
                        protectionSection
                        hairline
                        toolsSection(sel)
                        hairline
                        footer
                    }
                }
                .padding(12)
            }
        }
    }

    private var hairline: some View {
        FlatHairline()
    }

    // MARK: - Header

    private var header: some View {
        FlatBackBar(title: strings.diskSectionTitle, backLabel: strings.commonBack, onBack: onBack) {
            IconButton(systemImage: "arrow.clockwise", help: strings.monitorRefreshAll) {
                onRefresh()
            }
        }
    }

    // MARK: - Disk Selector

    private var diskSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskSelect, accent: diskAccent)
            let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(disks) { disk in
                    diskChip(disk)
                }
            }
        }
    }

    private func diskChip(_ disk: PhysicalDiskReading) -> some View {
        let isSelected = disk.id == (selectedDiskID ?? disks.first?.id)
        return Button {
            selectedDiskID = disk.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? diskAccent : MonitorOverviewPalette.secondary(colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                        .lineLimit(1)
                    Text(String(format: "%.0f%%", disk.usedFraction * 100))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? diskAccent.opacity(0.12) : MonitorOverviewPalette.pillBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? diskAccent.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Usage

    private func usageSection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskUsage, accent: diskAccent)

            VStack(alignment: .leading, spacing: 8) {
                // Title row
                HStack(spacing: 6) {
                    Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                        .font(.system(size: 13, weight: .semibold))
                    Text(disk.name)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                        .lineLimit(1)

                    labelCapsule(
                        disk.isInternal ? strings.diskInternal : strings.diskExternal,
                        color: disk.isInternal ? Theme.Stats.statusNormal : Theme.Stats.ram
                    )

                    if let fs = disk.fileSystem {
                        labelCapsule(fs, color: Theme.Stats.cpu)
                    } else {
                        labelCapsule(strings.diskFileSystemUnsupported, color: MonitorOverviewPalette.auxiliary(colorScheme))
                    }
                }

                // Progress bar
                MetricBar(
                    value: disk.usedFraction,
                    warning: 75,
                    critical: 90,
                    tint: MonitorCardAccent.barTint(for: .disk, progress: disk.usedFraction)
                )
                .frame(height: 4)

                // Stats
                HStack {
                    Text("\(Int(disk.usedFraction * 100))% \(strings.diskUsed)")
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))

                    Spacer()

                    Text("\(MetricFormat.diskBytes(disk.freeBytes)) \(strings.diskFree)")
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                }

                HStack {
                    Text("\(MetricFormat.diskBytes(disk.usedBytes)) / \(MetricFormat.diskBytes(disk.totalBytes))")
                        .font(Theme.Stats.font10Regular.monospacedDigit())
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    Spacer()
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Activity

    private func activitySection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskActivity, accent: diskAccent)

            HStack(alignment: .top, spacing: 20) {
                activityColumn(
                    icon: "arrow.down.circle",
                    tint: Theme.Stats.down,
                    label: strings.diskRead,
                    rate: MetricFormat.bytesPerSec(disk.readBytesPerSec),
                    total: disk.totalReadBytes
                )

                Spacer()

                activityColumn(
                    icon: "arrow.up.circle",
                    tint: Theme.Stats.up,
                    label: strings.diskWrite,
                    rate: MetricFormat.bytesPerSec(disk.writeBytesPerSec),
                    total: disk.totalWrittenBytes
                )
            }
            .padding(.horizontal, 4)
        }
    }

    /// 读/写列：标签行 → 速率大数字（与风扇 RPM 同层级）→ 会话累计小字。
    /// 「测量中」暂态与数值同字号，避免采样落定后行高跳变。
    private func activityColumn(icon: String, tint: Color, label: String, rate: String?, total: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(label)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
            }
            Text(rate ?? strings.diskMeasuring)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(rate == nil ? MonitorOverviewPalette.secondary(colorScheme) : MonitorOverviewPalette.primary(colorScheme))
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(strings.diskThisSession)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                Text(total.map { MetricFormat.diskBytes($0) } ?? strings.diskMeasuring)
                    .font(Theme.Stats.font10Regular.monospacedDigit())
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
        }
    }

    // MARK: - SMART

    private func smartSection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskSMART, accent: diskAccent)

            if let smart = disk.smart, smart.hasDetails {
                smartDetailRow(label: strings.diskSMARTStatus, value: smart.status)
                smartDetailRow(label: strings.diskTotalRead, value: smart.totalReadBytes.map { MetricFormat.diskBytes($0) })
                smartDetailRow(label: strings.diskTotalWritten, value: smart.totalWrittenBytes.map { MetricFormat.diskBytes($0) })
                smartDetailRow(
                    label: strings.diskTemperature,
                    value: MetricFormat.temperature(smart.temperatureCelsius, unit: temperatureUnit)
                )
                smartDetailRow(label: strings.diskHealth, value: smart.healthPercent.map { "\($0)%" })
                smartDetailRow(label: strings.diskPowerCycles, value: smart.powerCycles.map { "\($0)" })
                smartDetailRow(label: strings.diskPowerOnHours, value: smart.powerOnHours.map { "\($0) h" })
            } else {
                Text(strings.diskSMARTUnavailable)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
        }
    }

    private func smartDetailRow(label: String, value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .frame(width: 80, alignment: .leading)
            Text(value ?? strings.diskUnsupported)
                .font(Theme.Stats.font11Regular.monospacedDigit())
                .foregroundStyle(value == nil ? MonitorOverviewPalette.auxiliary(colorScheme) : MonitorOverviewPalette.primary(colorScheme))
            Spacer()
        }
    }

    // MARK: - Protection

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskProtection, accent: diskAccent)
            protectionContent
        }
    }

    @ViewBuilder
    private var protectionContent: some View {
        let ejectables = DiskProtectionService.uniqueEjectableDisks(from: disks)

        if ejectables.isEmpty {
            Text(strings.diskNoExternal)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(strings.diskEject) {
                        if let sel = selected, sel.canEject {
                            protection.eject(sel)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selected.map { !$0.canEject } ?? true)

                    Button(strings.diskEjectAll) {
                        protection.ejectAll(ejectables)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let sel = selected, let state = protection.state(for: sel.id) {
                    captionForState(state)
                } else {
                    Text(strings.diskProtectionCaption)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
            }
        }
    }

    @ViewBuilder
    private func captionForState(_ state: DiskEjectState) -> some View {
        switch state {
        case .ejecting:
            Text(strings.diskEjecting)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(Theme.Stats.ram)
        case .ready:
            Text(strings.diskReadyToRemove)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(Theme.Stats.statusNormal)
        case .failed(let message):
            Text("\(strings.diskEjectFailed): \(message)")
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(Theme.Stats.up)
        }
    }

    // MARK: - Tools

    private func toolsSection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskTools, accent: diskAccent)

            HStack(spacing: 8) {
                Button(strings.diskOpenInFinder) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: disk.primaryMountPath))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(strings.diskStorageSettings) {
                    let url = URL(fileURLWithPath: "/System/Library/PreferencePanes/Storage.prefPane")
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
    }

    // MARK: - Helpers

    private func labelCapsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Stats.font10Regular)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private func ensureSelectedDisk() {
        if selectedDiskID == nil || !disks.contains(where: { $0.id == selectedDiskID }) {
            selectedDiskID = disks.first?.id
        }
    }
}
