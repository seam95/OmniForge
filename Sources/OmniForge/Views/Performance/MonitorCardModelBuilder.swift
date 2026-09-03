import Foundation

/// View model for one overview metric card.
struct MonitorCardModel: Equatable, Identifiable {
    var id: MonitorCardID
    var title: String
    var systemImage: String
    var primaryText: String
    /// 设计稿 caption（灰色小字）
    var secondaryText: String?
    var progress: Double?
    var badgeText: String?
    var showsLiveDot: Bool
    var issueText: String?
    var processMetricKind: ProcessMetricKind?
    var opensDiskDetail: Bool = false
    /// 趋势折线数据（百分比卡 domain 0...1；网络为 bytes/s）
    var trend: [Double]? = nil
    /// 第二序列（仅网络：上传）
    var secondaryTrend: [Double]? = nil
    /// 速率文本（磁盘读/写、网络下行/上行，纯文本无方向前缀）
    var chipTexts: [String] = []
    /// 温度标记（三栏标签行右侧，仅 CPU/GPU）
    var temperatureText: String? = nil
}

/// Pure mapping from snapshot + history + configuration into overview card models.
enum MonitorCardModelBuilder {
    static func models(
        snapshot: SystemSnapshot,
        configuration: MonitorConfiguration,
        strings: Strings,
        temperatureUnit: TemperatureUnit,
        history: MetricHistory = MetricHistory()
    ) -> [MonitorCardModel] {
        MonitorCardID.visibleCards(configuration: configuration).map { id in
            model(
                for: id,
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit,
                history: history
            )
        }
    }

    private static func model(
        for id: MonitorCardID,
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit,
        history: MetricHistory
    ) -> MonitorCardModel {
        switch id {
        case .cpu:
            return cpuModel(
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit,
                history: history
            )
        case .memory:
            return memoryModel(snapshot: snapshot, strings: strings, history: history)
        case .battery:
            return batteryModel(
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit
            )
        case .disk:
            return diskCardModel(snapshot: snapshot, strings: strings)
        case .network:
            return networkModel(snapshot: snapshot, strings: strings, history: history)
        case .gpu:
            return gpuModel(
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit,
                history: history
            )
        case .energy:
            // 保留（排行代码沿用），overview 无入口
            return energyModel(snapshot: snapshot, strings: strings)
        }
    }

    // MARK: - Cards

    private static func cpuModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit,
        history: MetricHistory
    ) -> MonitorCardModel {
        let total = snapshot.cpuUsage?.total
        let secondary: String? = {
            guard let user = snapshot.cpuUsage?.user, let system = snapshot.cpuUsage?.system else {
                return nil
            }
            return "\(strings.monitorCPUSystem) \(MetricFormat.percent(system) ?? "--")"
                + " \(strings.monitorSubtitleSeparator) "
                + "\(strings.monitorCPUUser) \(MetricFormat.percent(user) ?? "--")"
        }()
        return MonitorCardModel(
            id: .cpu,
            title: strings.monitorMetricCpu,
            systemImage: "cpu",
            primaryText: MetricFormat.percent(total) ?? "--",
            secondaryText: secondary,
            progress: total,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.cpu], strings: strings),
            processMetricKind: .cpu,
            trend: history.cpu,
            temperatureText: MetricFormat.temperature(snapshot.cpuTemperature, unit: temperatureUnit)
        )
    }

    private static func memoryModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        history: MetricHistory
    ) -> MonitorCardModel {
        let used = snapshot.memoryUsed
        let total = snapshot.memoryTotal
        let fraction: Double? = {
            guard let used, let total, total > 0 else { return nil }
            return Double(used) / Double(total)
        }()
        // caption：`13.0 / 16 GB`（unknown 压力省略后缀）
        var captionParts: [String] = []
        if let pair = MetricFormat.shortMemoryPair(used: used, total: total) {
            captionParts.append(pair)
        }
        if let pressure = pressureSecondary(snapshot.memoryPressure, strings: strings) {
            captionParts.append(pressure)
        }
        let caption = captionParts.isEmpty ? nil : captionParts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
        return MonitorCardModel(
            id: .memory,
            title: strings.monitorMetricMemory,
            systemImage: "memorychip",
            primaryText: MetricFormat.percent(fraction) ?? "--",
            secondaryText: caption,
            progress: fraction,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.memory], strings: strings),
            processMetricKind: .memory,
            trend: history.memory
        )
    }

    private static func batteryModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit
    ) -> MonitorCardModel {
        guard let power = snapshot.power, power.hasBattery else {
            return MonitorCardModel(
                id: .battery,
                title: strings.monitorMetricBattery,
                systemImage: "battery.100",
                primaryText: strings.monitorNoPowerData,
                secondaryText: nil,
                progress: nil,
                badgeText: nil,
                showsLiveDot: false,
                issueText: issueText(for: snapshot.issues[.power], strings: strings),
                processMetricKind: nil
            )
        }

        // primary：`100% · 34°`
        var primaryParts: [String] = []
        if let level = MetricFormat.batteryLevel(power.batteryLevel) {
            primaryParts.append(level)
        }
        let tempValue = snapshot.batteryTemperature ?? power.batteryTemperature
        if let tempText = MetricFormat.temperature(tempValue, unit: temperatureUnit) {
            primaryParts.append(tempText)
        }
        let primary = primaryParts.isEmpty ? "--" : primaryParts.joined(separator: " \(strings.monitorSubtitleSeparator) ")

        // caption：`电源适配器 · 健康 90% · 12.4 W`（按有无拼接）
        var captionParts: [String] = []
        captionParts.append(
            (power.isCharging || power.externalConnected)
                ? strings.monitorPowerSourceAdapter
                : strings.monitorPowerSourceOnBattery
        )
        if let health = power.healthPercent {
            captionParts.append("\(strings.monitorMetricHealthShort) \(Int(health))%")
        }
        if let watts = power.batteryWatts {
            captionParts.append(String(format: "%.1f W", watts))
        }
        let caption = captionParts.isEmpty ? nil : captionParts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
        let systemImage = power.isCharging ? "battery.100.bolt" : "battery.100"

        return MonitorCardModel(
            id: .battery,
            title: strings.monitorMetricBattery,
            systemImage: systemImage,
            primaryText: primary,
            secondaryText: caption,
            progress: power.batteryLevel,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.power], strings: strings),
            processMetricKind: nil
        )
    }

    private static func diskCardModel(
        snapshot: SystemSnapshot,
        strings: Strings
    ) -> MonitorCardModel {
        // badge：`已用 238 GB`（total − free，base-1000）
        let free = snapshot.disk?.freeSpace
        let total = snapshot.disk?.totalSpace
        let badge: String? = {
            guard let free, let total, total > free else { return nil }
            return "\(strings.monitorDiskUsed) \(MetricFormat.diskBytes(total - free))"
        }()
        let readRate = snapshot.disk?.readBytesPerSec
        let writeRate = snapshot.disk?.writeBytesPerSec
        let readText = (readRate ?? 0) > 0
            ? MetricFormat.bytesPerSec(readRate!) : "--"
        let writeText = (writeRate ?? 0) > 0
            ? MetricFormat.bytesPerSec(writeRate!) : "--"
        return MonitorCardModel(
            id: .disk,
            title: strings.monitorCardDisk,
            systemImage: "internaldrive",
            primaryText: "--",
            secondaryText: nil,
            progress: nil,
            badgeText: badge,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.disk], strings: strings),
            processMetricKind: nil,
            opensDiskDetail: true,
            chipTexts: [readText, writeText]
        )
    }

    private static func networkModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        history: MetricHistory
    ) -> MonitorCardModel {
        let downRate = snapshot.netDownBytesPerSec
        let upRate = snapshot.netUpBytesPerSec
        let down = MetricFormat.bytesPerSec(downRate) ?? "--"
        let up = MetricFormat.bytesPerSec(upRate) ?? "--"
        // caption：`累计 ↓ 1.0 MB · ↑ 761 KB`
        let totalDown = MetricFormat.bytes(snapshot.netTotalDown) ?? "--"
        let totalUp = MetricFormat.bytes(snapshot.netTotalUp) ?? "--"
        let caption = "\(strings.monitorCumulativeTotal) ↓ \(totalDown)"
            + " \(strings.monitorSubtitleSeparator) ↑ \(totalUp)"
        return MonitorCardModel(
            id: .network,
            title: strings.monitorCardNetworkTraffic,
            systemImage: "wifi",
            primaryText: "--",
            secondaryText: caption,
            progress: nil,
            badgeText: strings.monitorLiveBadge,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.network], strings: strings),
            processMetricKind: .network,
            trend: history.netDown,
            secondaryTrend: history.netUp,
            chipTexts: [down, up]
        )
    }

    private static func gpuModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit,
        history: MetricHistory
    ) -> MonitorCardModel {
        // 大数字只放百分比；温度移到标签行右侧标记
        return MonitorCardModel(
            id: .gpu,
            title: strings.monitorMetricGpu,
            systemImage: "rectangle.3.group",
            primaryText: MetricFormat.percent(snapshot.gpuUsage) ?? "--",
            secondaryText: nil,
            progress: snapshot.gpuUsage,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.gpu], strings: strings),
            processMetricKind: .gpu,
            trend: history.gpu,
            temperatureText: MetricFormat.temperature(snapshot.gpuTemperature, unit: temperatureUnit)
        )
    }

    /// 保留：能耗排行代码沿用，overview 无入口（不可达）。
    private static func energyModel(
        snapshot: SystemSnapshot,
        strings: Strings
    ) -> MonitorCardModel {
        let primary: String = {
            guard let watts = snapshot.power?.systemWatts else { return "--" }
            return String(format: "%.1f W", watts)
        }()
        return MonitorCardModel(
            id: .energy,
            title: strings.monitorCardEnergy,
            systemImage: "bolt.fill",
            primaryText: primary,
            secondaryText: nil,
            progress: nil,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.power], strings: strings),
            processMetricKind: .energy
        )
    }

    // MARK: - Helpers

    private static func issueText(for issue: MetricIssue?, strings: Strings) -> String? {
        guard let issue else { return nil }
        switch issue {
        case .unsupported:
            return strings.monitorIssueUnsupported
        case .failed:
            return strings.monitorIssueFailed
        }
    }

    private static func pressureSecondary(_ pressure: MemoryPressure, strings: Strings) -> String? {
        switch pressure {
        case .normal: return strings.monitorPressureNormal
        case .warning: return strings.monitorPressureWarning
        case .critical: return strings.monitorPressureCritical
        case .unknown: return nil
        }
    }
}
