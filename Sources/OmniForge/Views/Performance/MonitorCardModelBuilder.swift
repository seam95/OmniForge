import Foundation

/// View model for one overview metric card.
struct MonitorCardModel: Equatable, Identifiable {
    var id: MonitorCardID
    var title: String
    var systemImage: String
    var primaryText: String
    var secondaryText: String?
    var progress: Double?
    var badgeText: String?
    var showsLiveDot: Bool
    var issueText: String?
    var processMetricKind: ProcessMetricKind?
    var opensDiskDetail: Bool = false
}

/// Pure mapping from snapshot + configuration into overview card models.
enum MonitorCardModelBuilder {
    static func models(
        snapshot: SystemSnapshot,
        configuration: MonitorConfiguration,
        strings: Strings,
        temperatureUnit: TemperatureUnit
    ) -> [MonitorCardModel] {
        MonitorCardID.visibleCards(configuration: configuration).map { id in
            model(
                for: id,
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit
            )
        }
    }

    private static func model(
        for id: MonitorCardID,
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit
    ) -> MonitorCardModel {
        switch id {
        case .cpu:
            return cpuModel(snapshot: snapshot, strings: strings, temperatureUnit: temperatureUnit)
        case .memory:
            return memoryModel(snapshot: snapshot, strings: strings)
        case .battery:
            return batteryModel(
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit
            )
        case .disk:
            return diskCardModel(snapshot: snapshot, strings: strings)
        case .network:
            return networkModel(snapshot: snapshot, strings: strings)
        case .gpu:
            return gpuModel(snapshot: snapshot, strings: strings, temperatureUnit: temperatureUnit)
        case .energy:
            return energyModel(snapshot: snapshot, strings: strings)
        }
    }

    // MARK: - Cards

    private static func cpuModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit
    ) -> MonitorCardModel {
        MonitorCardModel(
            id: .cpu,
            title: strings.monitorMetricCpu,
            systemImage: "cpu",
            primaryText: MetricFormat.percent(snapshot.cpuUsage) ?? "--",
            secondaryText: MetricFormat.temperature(snapshot.cpuTemperature, unit: temperatureUnit),
            progress: snapshot.cpuUsage,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.cpu], strings: strings),
            processMetricKind: .cpu
        )
    }

    private static func memoryModel(
        snapshot: SystemSnapshot,
        strings: Strings
    ) -> MonitorCardModel {
        let used = snapshot.memoryUsed
        let total = snapshot.memoryTotal
        let progress: Double? = {
            guard let used, let total, total > 0 else { return nil }
            return Double(used) / Double(total)
        }()
        // primary: used / total when both present; otherwise used alone or "--"
        let primary = MetricFormat.shortMemory(used, total: total)
            ?? MetricFormat.bytes(used)
            ?? "--"
        // secondary = 压力标签（unknown → nil）；比率通过 primary 和进度条体现
        let secondary = pressureSecondary(snapshot.memoryPressure, strings: strings)
        return MonitorCardModel(
            id: .memory,
            title: strings.monitorMetricMemory,
            systemImage: "memorychip",
            primaryText: primary,
            secondaryText: secondary,
            progress: progress,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.memory], strings: strings),
            processMetricKind: .memory
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

        var secondaryParts: [String] = []
        if power.isCharging {
            secondaryParts.append(strings.monitorMetricCharging)
        }
        if let watts = power.batteryWatts {
            secondaryParts.append(String(format: "%.1f W", watts))
        }
        if let remaining = power.timeRemaining {
            let minutes = Int(remaining / 60)
            secondaryParts.append(
                "\(strings.monitorMetricRemaining) \(minutes) min"
            )
        }
        // Prefer snapshot battery channel; fall back to power reading temperature.
        let tempValue = snapshot.batteryTemperature ?? power.batteryTemperature
        if let tempText = MetricFormat.temperature(tempValue, unit: temperatureUnit) {
            secondaryParts.append(tempText)
        }
        let secondary = secondaryParts.isEmpty
            ? nil
            : secondaryParts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
        let systemImage = power.isCharging ? "battery.100.bolt" : "battery.100"

        return MonitorCardModel(
            id: .battery,
            title: strings.monitorMetricBattery,
            systemImage: systemImage,
            primaryText: MetricFormat.batteryLevel(power.batteryLevel) ?? "--",
            secondaryText: secondary,
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
        let free = snapshot.disk?.freeSpace
        let total = snapshot.disk?.totalSpace
        let progress: Double? = {
            guard let free, let total, total > 0 else { return nil }
            let used = total > free ? total - free : 0
            return Double(used) / Double(total)
        }()
        let primary: String = {
            guard let free else { return "--" }
            return MetricFormat.diskBytes(free)
        }()
        let readRate = snapshot.disk?.readBytesPerSec
        let writeRate = snapshot.disk?.writeBytesPerSec
        let readText = (readRate ?? 0) > 0
            ? (MetricFormat.bytesPerSec(readRate!) ?? "--") : "--"
        let writeText = (writeRate ?? 0) > 0
            ? (MetricFormat.bytesPerSec(writeRate!) ?? "--") : "--"
        let secondary = "↓ \(readText) \(strings.monitorSubtitleSeparator) ↑ \(writeText)"
        return MonitorCardModel(
            id: .disk,
            title: strings.monitorCardDisk,
            systemImage: "internaldrive",
            primaryText: primary,
            secondaryText: secondary,
            progress: progress,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.disk], strings: strings),
            processMetricKind: nil,
            opensDiskDetail: true
        )
    }

    private static func networkModel(
        snapshot: SystemSnapshot,
        strings: Strings
    ) -> MonitorCardModel {
        let down = MetricFormat.bytesPerSec(snapshot.netDownBytesPerSec) ?? "--"
        let up = MetricFormat.bytesPerSec(snapshot.netUpBytesPerSec) ?? "--"
        let primary = "↓ \(down) \(strings.monitorSubtitleSeparator) ↑ \(up)"
        // Σ 前缀标记累计量，避免与 primary 速率行结构相同导致混淆
        let totalDown = MetricFormat.bytes(snapshot.netTotalDown) ?? "--"
        let totalUp = MetricFormat.bytes(snapshot.netTotalUp) ?? "--"
        let secondary = "Σ ↓ \(totalDown) \(strings.monitorSubtitleSeparator) ↑ \(totalUp)"
        return MonitorCardModel(
            id: .network,
            title: strings.monitorCardNetworkTraffic,
            systemImage: "wifi",
            primaryText: primary,
            secondaryText: secondary,
            progress: nil,
            badgeText: strings.monitorLiveBadge,
            showsLiveDot: true,
            issueText: issueText(for: snapshot.issues[.network], strings: strings),
            processMetricKind: .network
        )
    }

    private static func gpuModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit
    ) -> MonitorCardModel {
        MonitorCardModel(
            id: .gpu,
            title: strings.monitorMetricGpu,
            systemImage: "rectangle.3.group",
            primaryText: MetricFormat.percent(snapshot.gpuUsage) ?? "--",
            secondaryText: MetricFormat.temperature(snapshot.gpuTemperature, unit: temperatureUnit),
            progress: snapshot.gpuUsage,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.gpu], strings: strings),
            processMetricKind: .gpu
        )
    }


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
