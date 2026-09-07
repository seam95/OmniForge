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
    /// 大数字旁的次要文本（标签行右侧）：CPU/GPU 为温度，内存为已用量
    var accessoryText: String? = nil
    /// 风扇卡专用：快照是否有风扇读数（无风扇机器/未采样轮不出分区）
    var hasFanData = true
    /// 风扇卡专用：无风扇但有传感器读数时仍出分区（展示温度传感器摘要）
    var hasSensorData = false
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
        case .fan:
            return fanModel(
                snapshot: snapshot,
                strings: strings,
                temperatureUnit: temperatureUnit
            )
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
        return MonitorCardModel(
            id: .cpu,
            title: strings.monitorMetricCpu,
            systemImage: "cpu",
            primaryText: MetricFormat.percent(total) ?? "--",
            secondaryText: nil,
            progress: total,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.cpu], strings: strings),
            processMetricKind: .cpu,
            trend: history.cpu,
            accessoryText: MetricFormat.temperature(snapshot.cpuTemperature, unit: temperatureUnit)
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
        return MonitorCardModel(
            id: .memory,
            title: strings.monitorMetricMemory,
            systemImage: "memorychip",
            primaryText: MetricFormat.percent(fraction) ?? "--",
            secondaryText: nil,
            progress: fraction,
            badgeText: nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.memory], strings: strings),
            processMetricKind: .memory,
            trend: history.memory,
            accessoryText: MetricFormat.memoryUsedShort(used)
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
        // 大数字：已用量（total − free，base-1000，无前缀）
        let free = snapshot.disk?.freeSpace
        let total = snapshot.disk?.totalSpace
        let used: String? = {
            guard let free, let total, total > free else { return nil }
            return MetricFormat.diskBytes(total - free)
        }()
        // 标题行徽标：可用量
        let freeBadge: String? = free
            .flatMap { MetricFormat.diskBytes($0) }
            .map { "\(strings.monitorFreeLabel) \($0)" }
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
            primaryText: used ?? "--",
            secondaryText: nil,
            progress: nil,
            badgeText: freeBadge,
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
            accessoryText: MetricFormat.temperature(snapshot.gpuTemperature, unit: temperatureUnit)
        )
    }

    /// 风扇卡：有风扇时标题行右侧最高转速、caption 逐风扇 RPM；
    /// 无风扇但有传感器时标题改「温度传感器」、主值取最高温、caption 为前两热点组（传感器仍可监控）。
    private static func fanModel(
        snapshot: SystemSnapshot,
        strings: Strings,
        temperatureUnit: TemperatureUnit
    ) -> MonitorCardModel {
        let fans = snapshot.fans
        if fans.isEmpty {
            // 无风扇机型：退化为温度传感器摘要卡。
            // 主值 = 过滤 unknown 后的最高温（与详情页 FanSensorGroupSummary 同源口径），
            // caption = 前两热点组「组名 组内最高温」，回答「哪里最热」。
            let summaries = FanSensorGroupSummary.summaries(from: snapshot.sensors)
            let peak = summaries.compactMap(\.hottest?.temperatureCelsius).max()
            let peakText = peak.flatMap { MetricFormat.temperature($0, unit: temperatureUnit) }
            let hotspotParts = summaries.prefix(2).compactMap { summary -> String? in
                guard let hottest = summary.hottest,
                      let text = MetricFormat.temperature(hottest.temperatureCelsius, unit: temperatureUnit)
                else { return nil }
                return "\(strings.fanZoneName(summary.zone)) \(text)"
            }
            let hotspotCaption = hotspotParts.isEmpty
                ? nil
                : hotspotParts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
            let count = snapshot.sensors.count
            return MonitorCardModel(
                id: .fan,
                title: strings.fanSensorSectionTitle,
                systemImage: "thermometer.medium",
                primaryText: peakText ?? "--",
                secondaryText: hotspotCaption,
                progress: nil,
                badgeText: nil,
                showsLiveDot: false,
                issueText: issueText(for: snapshot.issues[.fan], strings: strings),
                processMetricKind: nil,
                hasFanData: false,
                hasSensorData: count > 0
            )
        }
        let peak = fans.map(\.currentRPM).max() ?? 0
        let peakFraction = fans.map(\.speedFraction).max() ?? 0
        let anyManual = fans.contains { $0.isManualMode }
        // caption：`3200 RPM • 3400 RPM`（或单风扇 `3200 RPM`）
        let caption = fans
            .compactMap { MetricFormat.rpm($0.currentRPM).map { "\($0) RPM" } }
            .joined(separator: " \(strings.monitorSubtitleSeparator) ")
        return MonitorCardModel(
            id: .fan,
            title: strings.monitorCardFan,
            systemImage: "fanblades",
            primaryText: (MetricFormat.rpm(peak).map { "\($0) RPM" }) ?? "--",
            secondaryText: caption.isEmpty ? nil : caption,
            progress: peakFraction,
            badgeText: anyManual ? strings.fanModeManualBadge : nil,
            showsLiveDot: false,
            issueText: issueText(for: snapshot.issues[.fan], strings: strings),
            processMetricKind: nil
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
}
