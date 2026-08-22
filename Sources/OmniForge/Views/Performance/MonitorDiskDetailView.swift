import SwiftUI

/// 磁盘详情页：选盘 → 使用 → 活动 → SMART → 保护 → 工具。
/// 对齐 SPEC §3.3–3.9，无编辑排序（区别于 vorssaint）。
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
        VStack(spacing: 12) {
            header
            Spacer()
            Text(strings.diskNoDisks)
                .foregroundStyle(.secondary)
                .font(.title3)
            Spacer()
            footer
        }
        .padding(12)
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                diskSelector
                if let sel = selected {
                    usageSection(sel)
                    activitySection(sel)
                    smartSection(sel)
                    protectionAndToolsSection(sel)
                }
                Divider()
                footer
            }
            .padding(12)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text(strings.diskSectionTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Disk Selector

    private var diskSelector: some View {
        sectionBlock(title: strings.diskSelect) {
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
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(String(format: "%.0f%%", disk.usedFraction * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Usage

    private func usageSection(_ disk: PhysicalDiskReading) -> some View {
        sectionBlock(title: strings.diskUsage) {
            VStack(alignment: .leading, spacing: 8) {
                // Title row
                HStack(spacing: 6) {
                    Image(systemName: disk.isInternal ? "internaldrive" : "externaldrive")
                        .font(.headline)
                    Text(disk.name)
                        .font(.headline)
                        .lineLimit(1)

                    labelCapsule(
                        disk.isInternal ? strings.diskInternal : strings.diskExternal,
                        color: disk.isInternal ? .green : .orange
                    )

                    if let fs = disk.fileSystem {
                        labelCapsule(fs, color: .blue)
                    } else {
                        labelCapsule(strings.diskFileSystemUnsupported, color: .secondary)
                    }
                }

                // Progress bar
                MetricBar(
                    value: disk.usedFraction,
                    warning: 75,
                    critical: 90,
                    tint: MonitorCardAccent.barTint(for: .disk, progress: disk.usedFraction)
                )
                .frame(height: 6)

                // Stats
                HStack {
                    Text("\(Int(disk.usedFraction * 100))% \(strings.diskUsed)")
                        .font(.caption.weight(.medium))

                    Spacer()

                    Text("\(MetricFormat.diskBytes(disk.freeBytes)) \(strings.diskFree)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(MetricFormat.diskBytes(disk.usedBytes)) / \(MetricFormat.diskBytes(disk.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Activity

    private func activitySection(_ disk: PhysicalDiskReading) -> some View {
        sectionBlock(title: strings.diskActivity) {
            HStack(alignment: .top, spacing: 20) {
                // Read
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(strings.diskRead)
                            .font(.caption.weight(.medium))
                    }
                    let rate = MetricFormat.bytesPerSec(disk.readBytesPerSec) ?? strings.diskMeasuring
                    Text(rate)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(strings.diskThisSession)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(disk.totalReadBytes.map { MetricFormat.diskBytes($0) } ?? strings.diskMeasuring)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Write
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(strings.diskWrite)
                            .font(.caption.weight(.medium))
                    }
                    let rate = MetricFormat.bytesPerSec(disk.writeBytesPerSec) ?? strings.diskMeasuring
                    Text(rate)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(strings.diskThisSession)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(disk.totalWrittenBytes.map { MetricFormat.diskBytes($0) } ?? strings.diskMeasuring)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - SMART

    private func smartSection(_ disk: PhysicalDiskReading) -> some View {
        sectionBlock(title: strings.diskSMART) {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func smartDetailRow(label: String, value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value ?? strings.diskUnsupported)
                .font(.caption.weight(.medium))
                .foregroundStyle(value == nil ? .secondary : .primary)
            Spacer()
        }
    }

    // MARK: - Protection & Tools

    private func protectionAndToolsSection(_ disk: PhysicalDiskReading) -> some View {
        HStack(alignment: .top, spacing: 12) {
            protectionCard
                .frame(maxWidth: .infinity, alignment: .topLeading)
            toolsCard(disk)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var protectionCard: some View {
        sectionBlock(title: strings.diskProtection) {
            protectionContent
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func toolsCard(_ disk: PhysicalDiskReading) -> some View {
        sectionBlock(title: strings.diskTools) {
            toolsContent(disk)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var protectionContent: some View {
        let ejectables = DiskProtectionService.uniqueEjectableDisks(from: disks)

        if ejectables.isEmpty {
            Text(strings.diskNoExternal)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func captionForState(_ state: DiskEjectState) -> some View {
        switch state {
        case .ejecting:
            Text(strings.diskEjecting)
                .font(.caption2)
                .foregroundStyle(.orange)
        case .ready:
            Text(strings.diskReadyToRemove)
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let message):
            Text("\(strings.diskEjectFailed): \(message)")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private func toolsContent(_ disk: PhysicalDiskReading) -> some View {
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if showsSettingsAction {
                Button(strings.monitorPreferences, action: onOpenSettings)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.medium))
            }
            Spacer()
            Button(strings.monitorRefreshAll, action: onRefresh)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption.weight(.medium))
        }
    }

    // MARK: - Helpers

    private func sectionBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func labelCapsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
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
