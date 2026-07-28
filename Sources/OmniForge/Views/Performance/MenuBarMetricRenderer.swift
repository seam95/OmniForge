import Foundation
import AppKit

enum MenuBarMetricRenderer {
    /// 单个指标块：label 上、value 下，用 minimumValue 预留宽度防抖动
    struct MetricBlock: Equatable {
        let label: String
        let value: String
        let minimumValue: String
        var pressure: MemoryPressure? = nil
    }

    /// 根据快照和启用的指标渲染多栏 attributed string 分组（每组为 attachment 图像）
    static func attributedGroups(
        for snapshot: SystemSnapshot,
        metrics: [MenuBarMetric],
        configuration: MonitorConfiguration
    ) -> [NSAttributedString] {
        blocks(for: snapshot, metrics: metrics, configuration: configuration).map { block in
            attachment(for: block, spacing: configuration.menuBarSpacing)
        }
    }

    /// 合并模式：按间距将各组拼成单一 attributed title
    static func attributedTitle(
        for snapshot: SystemSnapshot,
        metrics: [MenuBarMetric],
        configuration: MonitorConfiguration
    ) -> NSAttributedString {
        let groups = attributedGroups(for: snapshot, metrics: metrics, configuration: configuration)
        guard !groups.isEmpty else {
            return NSAttributedString(string: "")
        }

        let gap = configuration.menuBarSpacing == .compact
            ? MenuBarMetricLayout.compactSpacing
            : MenuBarMetricLayout.standardSpacing
        let spacer = spacerAttachment(width: gap)

        let result = NSMutableAttributedString()
        for (index, group) in groups.enumerated() {
            if index > 0 {
                result.append(spacer)
            }
            result.append(group)
        }
        return result
    }

    /// 结构化块内容（测试与渲染共用）
    static func blocks(
        for snapshot: SystemSnapshot,
        metrics: [MenuBarMetric],
        configuration: MonitorConfiguration
    ) -> [MetricBlock] {
        let enabled = Set(metrics)
        return metrics.compactMap { metric in
            // 合并温度开启且对应占用指标也启用时，温度并入 CPU/GPU，不再单独出块
            if configuration.combineTemperatures {
                if metric == .cpuTemperature, enabled.contains(.cpu) {
                    return nil
                }
                if metric == .gpuTemperature, enabled.contains(.gpu) {
                    return nil
                }
            }
            return block(
                for: metric,
                snapshot: snapshot,
                configuration: configuration,
                enabledMetrics: enabled
            )
        }
    }

    // MARK: - 块内容

    private static func block(
        for metric: MenuBarMetric,
        snapshot: SystemSnapshot,
        configuration: MonitorConfiguration,
        enabledMetrics: Set<MenuBarMetric>
    ) -> MetricBlock? {
        switch metric {
        case .cpu:
            if snapshot.issues[.cpu] != nil {
                return MetricBlock(label: "CPU", value: "--", minimumValue: "100%")
            }
            if let usage = snapshot.cpuUsage {
                let pct = MetricFormat.percent(usage) ?? "--"
                // 仅当用户勾选了 CPU 温度时才拼入；合并开关本身不隐式启用温度
                if configuration.combineTemperatures,
                   enabledMetrics.contains(.cpuTemperature),
                   let temp = snapshot.cpuTemperature,
                   let tempStr = MetricFormat.temperature(temp, unit: configuration.temperatureUnit) {
                    return MetricBlock(
                        label: "CPU",
                        value: "\(pct) \(tempStr)",
                        minimumValue: Self.percentTempMinimum(unit: configuration.temperatureUnit)
                    )
                }
                return MetricBlock(label: "CPU", value: pct, minimumValue: "100%")
            }
            return MetricBlock(label: "CPU", value: "--", minimumValue: "100%")

        case .gpu:
            if snapshot.issues[.gpu] != nil {
                return MetricBlock(label: "GPU", value: "--", minimumValue: "100%")
            }
            if let usage = snapshot.gpuUsage {
                let pct = MetricFormat.percent(usage) ?? "--"
                if configuration.combineTemperatures,
                   enabledMetrics.contains(.gpuTemperature),
                   let temp = snapshot.gpuTemperature,
                   let tempStr = MetricFormat.temperature(temp, unit: configuration.temperatureUnit) {
                    return MetricBlock(
                        label: "GPU",
                        value: "\(pct) \(tempStr)",
                        minimumValue: Self.percentTempMinimum(unit: configuration.temperatureUnit)
                    )
                }
                return MetricBlock(label: "GPU", value: pct, minimumValue: "100%")
            }
            return MetricBlock(label: "GPU", value: "--", minimumValue: "100%")

        case .memory:
            return memoryBlock(for: snapshot, style: configuration.menuBarMemoryStyle)

        case .network:
            return networkBlock(for: snapshot, uploadFirst: configuration.networkUploadFirst)

        case .disk:
            if let free = snapshot.disk?.freeSpace {
                let freeStr = MetricFormat.diskBytes(free)
                return MetricBlock(label: "DSK", value: freeStr, minimumValue: "00.00 GB")
            }
            return MetricBlock(label: "DSK", value: "--", minimumValue: "00.00 GB")

        case .power:
            if let level = snapshot.power?.batteryLevel {
                return MetricBlock(
                    label: "PWR",
                    value: MetricFormat.batteryLevel(level) ?? "--",
                    minimumValue: "100%"
                )
            }
            return MetricBlock(label: "PWR", value: "--", minimumValue: "100%")

        case .batteryTemperature:
            return temperatureBlock(
                label: "BAT°",
                value: snapshot.batteryTemperature,
                unit: configuration.temperatureUnit
            )

        case .cpuTemperature:
            return temperatureBlock(
                label: "CPU°",
                value: snapshot.cpuTemperature,
                unit: configuration.temperatureUnit
            )

        case .gpuTemperature:
            return temperatureBlock(
                label: "GPU°",
                value: snapshot.gpuTemperature,
                unit: configuration.temperatureUnit
            )

        case .peripheralBattery:
            let levels = snapshot.peripheralBatteries
                .map { MetricFormat.batteryLevel($0.level) ?? "--" }
                .joined(separator: "/")
            let value = levels.isEmpty ? "--" : levels
            return MetricBlock(label: "BT", value: value, minimumValue: "100%")

        case .date:
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            guard let sampledAt = snapshot.sampledAt else { return nil }
            let text = formatter.string(from: sampledAt)
            return MetricBlock(label: " ", value: text, minimumValue: "00/00 00:00")

        case .battery:
            if let power = snapshot.power {
                return MetricBlock(
                    label: "BAT",
                    value: MetricFormat.batteryLevel(power.batteryLevel) ?? "--",
                    minimumValue: "100%"
                )
            }
            return MetricBlock(label: "BAT", value: "--", minimumValue: "100%")
        }
    }

    private static func memoryBlock(for snapshot: SystemSnapshot, style: MemoryMenuBarStyle) -> MetricBlock {
        switch style {
        case .percent:
            if let pct = MetricFormat.memory(snapshot.memoryUsed, total: snapshot.memoryTotal) {
                return MetricBlock(
                    label: "RAM",
                    value: pct,
                    minimumValue: "100%",
                    pressure: snapshot.memoryPressure == .unknown ? nil : snapshot.memoryPressure
                )
            }
            return MetricBlock(label: "RAM", value: "--", minimumValue: "100%")
        case .used:
            if let used = MetricFormat.bytes(snapshot.memoryUsed) {
                return MetricBlock(label: "RAM", value: used, minimumValue: "00.00 GB")
            }
            return MetricBlock(label: "RAM", value: "--", minimumValue: "00.00 GB")
        case .pressure:
            return MetricBlock(
                label: "RAM",
                value: pressureLabel(snapshot.memoryPressure),
                minimumValue: "WARN",
                pressure: snapshot.memoryPressure == .unknown ? nil : snapshot.memoryPressure
            )
        }
    }

    private static func networkBlock(for snapshot: SystemSnapshot, uploadFirst: Bool) -> MetricBlock {
        let down = MetricFormat.bytesPerSec(snapshot.netDownBytesPerSec) ?? "--"
        let up = MetricFormat.bytesPerSec(snapshot.netUpBytesPerSec) ?? "--"
        let value: String
        if uploadFirst {
            value = "↑\(up) ↓\(down)"
        } else {
            value = "↓\(down) ↑\(up)"
        }
        // 网速位数变化大，用较宽占位降低抖动
        return MetricBlock(label: "NET", value: value, minimumValue: "↓000.0 MB/s ↑000.0 MB/s")
    }

    private static func pressureLabel(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: return "OK"
        case .warning: return "WARN"
        case .critical: return "CRIT"
        case .unknown: return "--"
        }
    }

    private static func temperatureBlock(
        label: String,
        value: Double?,
        unit: TemperatureUnit
    ) -> MetricBlock {
        guard let value,
              let text = MetricFormat.temperature(value, unit: unit) else {
            return MetricBlock(label: label, value: "--", minimumValue: Self.tempMinimum(unit: unit))
        }
        return MetricBlock(label: label, value: text, minimumValue: Self.tempMinimum(unit: unit))
    }

    /// 温度占位最小宽度，跟随单位后缀
    private static func tempMinimum(unit: TemperatureUnit) -> String {
        unit == .fahrenheit ? "999°F" : "999°"
    }

    /// 百分比 + 合并温度的占位最小宽度
    private static func percentTempMinimum(unit: TemperatureUnit) -> String {
        unit == .fahrenheit ? "100% 999°F" : "100% 999°"
    }

    // MARK: - 图像块

    private static func attachment(
        for block: MetricBlock,
        spacing: MenuBarMetricSpacing
    ) -> NSAttributedString {
        let image = metricBlockImage(
            label: block.label,
            value: block.value,
            minimumValue: block.minimumValue,
            spacing: spacing,
            pressure: block.pressure
        )
        let attachment = NSTextAttachment()
        attachment.image = image
        // 与菜单栏基线对齐
        attachment.bounds = NSRect(x: 0, y: -5.5, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// 绘制 label/value 双行块；宽度取 max(value, 预留候选) 避免位数/单位变化抖动
    static func metricBlockImage(
        label: String,
        value: String,
        minimumValue reservedValue: String,
        spacing: MenuBarMetricSpacing = .standard,
        pressure: MemoryPressure? = nil
    ) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 6.6, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
        let sizingLabelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let sizingValueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont]

        // compact：位数高水位 + 指标绝对 minimumValue 取较宽者；
        // standard：仅用绝对 maximum。避免 compact 只看位数时 NET 单位切换仍抖动。
        let reserveCandidates: [String]
        if spacing == .compact {
            reserveCandidates = [
                MenuBarMetricLayout.compactReserve(label: label, value: value),
                reservedValue,
            ]
        } else {
            reserveCandidates = [reservedValue]
        }

        let labelSize = (label as NSString).size(withAttributes: sizingLabelAttrs)
        let valueSize = (value as NSString).size(withAttributes: sizingValueAttrs)
        let reserveWidth = reserveCandidates
            .map { ($0 as NSString).size(withAttributes: sizingValueAttrs).width }
            .max() ?? 0

        let hasPressureDot = pressure != nil && pressure != .unknown
        let dotDiameter: CGFloat = hasPressureDot ? 4.8 : 0
        let dotGap: CGFloat = hasPressureDot && !value.isEmpty ? 4 : 0
        let reservedValueWidth = max(valueSize.width, reserveWidth)
        let reservedGroupWidth = dotDiameter + dotGap + reservedValueWidth
        let drawnGroupWidth = dotDiameter + dotGap + valueSize.width
        let width = ceil(max(labelSize.width, reservedGroupWidth, MenuBarMetricLayout.minItemWidth) + 0.5)
        let height: CGFloat = 21

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.labelColor
            ]
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: valueFont,
                .foregroundColor: NSColor.labelColor
            ]

            (label as NSString).draw(
                at: NSPoint(x: (width - labelSize.width) / 2, y: 12.0),
                withAttributes: labelAttrs
            )

            var valueX = (width - drawnGroupWidth) / 2
            if hasPressureDot, let pressure {
                let dotRect = NSRect(x: valueX, y: 3.5, width: dotDiameter, height: dotDiameter)
                color(for: pressure).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                valueX += dotDiameter + dotGap
            }

            (value as NSString).draw(
                at: NSPoint(x: valueX, y: -0.8),
                withAttributes: valueAttrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func spacerAttachment(width: CGFloat) -> NSAttributedString {
        let size = NSSize(width: max(1, width), height: 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func color(for pressure: MemoryPressure) -> NSColor {
        switch pressure {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }
}
