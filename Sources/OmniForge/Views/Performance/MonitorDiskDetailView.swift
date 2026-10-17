import SwiftUI
import AppKit

/// 磁盘详情页（卡片化与层次感仪表盘）：选盘（多盘时） → 存储主卡片 → 实时活动 → SMART 遥测 → 外置保护 → 快捷工具。
/// 契合全白底（#FFFFFF）现代设计语言，消除发丝线割裂，强化视觉焦点与信息层级。
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

    /// 磁盘强调色（与监控 overview 磁盘卡同源）
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
        .background(colorScheme == .light ? Color.white : Color.clear)
        .onAppear(perform: ensureSelectedDisk)
        .onChange(of: disks.map(\.id)) { _, _ in ensureSelectedDisk() }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 14) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(diskAccent.opacity(0.10))
                        .frame(width: 56, height: 56)
                    Image(systemName: "internaldrive")
                        .font(.system(size: 26))
                        .foregroundStyle(diskAccent)
                }
                Text(strings.diskNoDisks)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .font(Theme.Stats.font13SemiBold)
                Spacer()
                footer
            }
            .padding(14)
        }
    }

    // MARK: - Content View

    private var contentView: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // 多磁盘时才展示顶部切换条；单磁盘直接在主卡片中体现身份
                    if disks.count > 1 {
                        diskSelector
                    }

                    if let sel = selected {
                        usageHeroSection(sel)
                        activitySection(sel)
                        smartSection(sel)
                        protectionSection
                        toolsSection(sel)
                    }

                    footer
                }
                .padding(14)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        FlatBackBar(title: strings.diskSectionTitle, backLabel: strings.commonBack, onBack: onBack) {
            IconButton(systemImage: "arrow.clockwise", help: strings.monitorRefreshAll) {
                onRefresh()
            }
        }
    }

    // MARK: - Disk Selector (Multi-disk)

    private var diskSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskSelect, accent: diskAccent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(disks) { disk in
                        diskChip(disk)
                    }
                }
            }
        }
    }

    private func diskChip(_ disk: PhysicalDiskReading) -> some View {
        let isSelected = disk.id == (selectedDiskID ?? disks.first?.id)
        return Button {
            withAnimation(Theme.Animation.snappy) {
                selectedDiskID = disk.id
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? diskAccent : MonitorOverviewPalette.secondary(colorScheme))

                Text(disk.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MonitorOverviewPalette.primary(colorScheme) : MonitorOverviewPalette.secondary(colorScheme))
                    .lineLimit(1)

                Text(String(format: "%.0f%%", disk.usedFraction * 100))
                    .font(Theme.Stats.font10Regular.monospacedDigit())
                    .foregroundStyle(isSelected ? diskAccent : MonitorOverviewPalette.auxiliary(colorScheme))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSelected ? diskAccent.opacity(0.12) : Color.primary.opacity(0.05))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? diskAccent.opacity(0.10) : MonitorOverviewPalette.pillBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? diskAccent.opacity(0.5) : (colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.06)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Storage Hero Card

    private func usageHeroSection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskUsage, accent: diskAccent)

            cardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    // Top identity row
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(diskAccent.opacity(0.12))
                                .frame(width: 32, height: 32)
                            Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(diskAccent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                                Text(disk.primaryMountPath)
                                    .font(Theme.Stats.font10Regular)
                                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        // Tags & file system
                        HStack(spacing: 6) {
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
                    }

                    // Hero capacity numbers: highlight Free Space prominent callout
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(MetricFormat.diskBytes(disk.freeBytes))
                                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))

                            Text(strings.diskFree)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))

                            Spacer()

                            Text(String(format: "%.0f%%", disk.usedFraction * 100) + " " + strings.diskUsed)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MonitorCardAccent.barTint(for: .disk, progress: disk.usedFraction))
                        }

                        Text("\(MetricFormat.diskBytes(disk.usedBytes)) / \(MetricFormat.diskBytes(disk.totalBytes))")
                            .font(Theme.Stats.font11Regular.monospacedDigit())
                            .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    }

                    // Continuous modern 8pt progress bar
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let clamped = min(max(disk.usedFraction, 0), 1)
                        let fillWidth = max(0, min(width, width * clamped))

                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(colorScheme == .light ? Color.black.opacity(0.06) : Color.white.opacity(0.12))
                                .frame(height: 8)

                            if fillWidth > 0 {
                                Capsule(style: .continuous)
                                    .fill(MonitorCardAccent.barTint(for: .disk, progress: disk.usedFraction))
                                    .frame(width: fillWidth, height: 8)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 8)
                }
            }
        }
    }

    // MARK: - Activity Section (Dual Mini-Cards)

    private func activitySection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskActivity, accent: diskAccent)

            HStack(spacing: 10) {
                activityCard(
                    icon: "arrow.down",
                    tint: Theme.Stats.down,
                    label: strings.diskRead,
                    rate: MetricFormat.bytesPerSec(disk.readBytesPerSec),
                    total: disk.totalReadBytes
                )

                activityCard(
                    icon: "arrow.up",
                    tint: Theme.Stats.up,
                    label: strings.diskWrite,
                    rate: MetricFormat.bytesPerSec(disk.writeBytesPerSec),
                    total: disk.totalWrittenBytes
                )
            }
        }
    }

    private func activityCard(
        icon: String,
        tint: Color,
        label: String,
        rate: String?,
        total: UInt64?
    ) -> some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.12))
                            .frame(width: 22, height: 22)
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                    }

                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))

                    Spacer()
                }

                Text(rate ?? strings.diskMeasuring)
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rate == nil ? MonitorOverviewPalette.auxiliary(colorScheme) : MonitorOverviewPalette.primary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 4) {
                    Text(strings.diskThisSession)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    Text(total.map { MetricFormat.diskBytes($0) } ?? strings.diskMeasuring)
                        .font(Theme.Stats.font10Regular.monospacedDigit())
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - SMART Telemetry

    private func smartSection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskSMART, accent: diskAccent)

            if let smart = disk.smart, smart.hasDetails {
                cardContainer {
                    VStack(alignment: .leading, spacing: 10) {
                        // Badges header row
                        HStack(spacing: 8) {
                            if let status = smart.status {
                                let isNormal = status.localizedCaseInsensitiveContains("verified")
                                    || status.localizedCaseInsensitiveContains("ok")
                                    || status.contains("正常")
                                StatusTintBadge(
                                    text: status,
                                    tint: isNormal ? Theme.Stats.statusNormal : Theme.Stats.up
                                )
                            }

                            if let temp = smart.temperatureCelsius,
                               let tempStr = MetricFormat.temperature(temp, unit: temperatureUnit) {
                                HStack(spacing: 4) {
                                    Image(systemName: "thermometer.medium")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(tempStr)
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                }
                                .foregroundStyle(Theme.Stats.ram)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Theme.Stats.ram.opacity(0.12))
                                )
                            }

                            if let health = smart.healthPercent {
                                HStack(spacing: 4) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 9))
                                    Text("\(health)% \(strings.diskHealth)")
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                }
                                .foregroundStyle(Theme.Stats.statusNormal)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Theme.Stats.statusNormal.opacity(0.12))
                                )
                            }

                            Spacer()
                        }

                        // Divider inside card
                        Rectangle()
                            .fill(colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                            .frame(height: 1)

                        // 2-Column Telemetry Grid
                        let columns = [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ]

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            smartGridItem(label: strings.diskTotalRead, value: smart.totalReadBytes.map { MetricFormat.diskBytes($0) })
                            smartGridItem(label: strings.diskTotalWritten, value: smart.totalWrittenBytes.map { MetricFormat.diskBytes($0) })
                            smartGridItem(label: strings.diskPowerOnHours, value: smart.powerOnHours.map { "\($0) h" })
                            smartGridItem(label: strings.diskPowerCycles, value: smart.powerCycles.map { "\($0)" })

                            if let shutdowns = smart.unsafeShutdowns {
                                smartGridItem(label: "异常关机", value: "\(shutdowns)")
                            }
                            if let errors = smart.mediaErrors {
                                smartGridItem(label: "介质错误", value: "\(errors)")
                            }
                        }
                    }
                }
            } else {
                cardContainer {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                        Text(strings.diskSMARTUnavailable)
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func smartGridItem(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
            Text(value ?? strings.diskUnsupported)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(value == nil ? MonitorOverviewPalette.auxiliary(colorScheme) : MonitorOverviewPalette.primary(colorScheme))
                .lineLimit(1)
        }
    }

    // MARK: - Protection Section

    @ViewBuilder
    private var protectionSection: some View {
        let ejectables = DiskProtectionService.uniqueEjectableDisks(from: disks)

        if !ejectables.isEmpty || disks.contains(where: { !$0.isInternal }) {
            VStack(alignment: .leading, spacing: 8) {
                FlatSectionHeader(title: strings.diskProtection, accent: diskAccent)

                cardContainer {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            if let sel = selected, sel.canEject {
                                Button {
                                    protection.eject(sel)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "eject.fill")
                                            .font(.system(size: 10))
                                        Text("\(strings.diskEject) (\(sel.name))")
                                            .font(Theme.Stats.font11Regular)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.Stats.ram)
                                .controlSize(.small)
                            }

                            if ejectables.count > 1 || (selected?.canEject != true && !ejectables.isEmpty) {
                                Button {
                                    protection.ejectAll(ejectables)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "eject")
                                            .font(.system(size: 10))
                                        Text("\(strings.diskEjectAll) (\(ejectables.count))")
                                            .font(Theme.Stats.font11Regular)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if ejectables.isEmpty {
                                Text(strings.diskNoExternal)
                                    .font(Theme.Stats.font11Regular)
                                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                            }

                            Spacer()
                        }

                        if let sel = selected, let state = protection.state(for: sel.id) {
                            captionForState(state)
                        } else if !ejectables.isEmpty {
                            Text(strings.diskProtectionCaption)
                                .font(Theme.Stats.font10Regular)
                                .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func captionForState(_ state: DiskEjectState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .ejecting:
                ProgressView()
                    .controlSize(.mini)
                Text(strings.diskEjecting)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(Theme.Stats.ram)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Stats.statusNormal)
                Text(strings.diskReadyToRemove)
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(Theme.Stats.statusNormal)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Stats.up)
                Text("\(strings.diskEjectFailed): \(message)")
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(Theme.Stats.up)
            }
        }
    }

    // MARK: - Tools Section

    private func toolsSection(_ disk: PhysicalDiskReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.diskTools, accent: diskAccent)

            HStack(spacing: 10) {
                toolActionButton(
                    icon: "folder",
                    label: strings.diskOpenInFinder
                ) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: disk.primaryMountPath))
                }

                toolActionButton(
                    icon: "gearshape",
                    label: strings.diskStorageSettings
                ) {
                    let url = URL(fileURLWithPath: "/System/Library/PreferencePanes/Storage.prefPane")
                    NSWorkspace.shared.open(url)
                }

                Spacer()
            }
        }
    }

    private func toolActionButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                Text(label)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MonitorOverviewPalette.pillBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
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
        .padding(.top, 4)
    }

    // MARK: - Card Container & Helpers

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .light ? Color(red: 0xF6/255.0, green: 0xF7/255.0, blue: 0xF9/255.0) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        colorScheme == .light ? Color.black.opacity(0.04) : Color.white.opacity(0.06),
                        lineWidth: 1
                    )
            )
    }

    private func labelCapsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
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
