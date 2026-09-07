import Foundation
import AppKit

enum MenuBarMetricRenderer {
    /// 单个指标块：label 上、value 下，用 minimumValue 预留宽度防抖动
    struct MetricBlock: Equatable {
        let label: String
        let value: String
        let minimumValue: String
        var pressure: MemoryPressure? = nil
        /// 第二行值与预留（网速堆叠布局专用）：非 nil 时整块按双行小字渲染、不绘制 label，
        /// label 仅作为 compact 水位键与测试标识保留
        var secondaryValue: String? = nil
        var secondaryMinimumValue: String? = nil
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

    /// 从任意 MetricBlock 渲染单个指标块（Token 菜单栏等非 monitor 指标复用）。
    static func attributedTitle(
        for block: MetricBlock,
        spacing: MenuBarMetricSpacing = .standard
    ) -> NSAttributedString {
        attachment(for: block, spacing: spacing)
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
            // 合并温度开启且对应占用指标也启用时，温度并入 CPU/GPU/电池，不再单独出块
            if configuration.combineTemperatures {
                if metric == .cpuTemperature, enabled.contains(.cpu) {
                    return nil
                }
                if metric == .gpuTemperature, enabled.contains(.gpu) {
                    return nil
                }
                if metric == .batteryTemperature, enabled.contains(.battery) {
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
                let pct = MetricFormat.percent(usage.total) ?? "--"
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

        case .fan:
            if snapshot.issues[.fan] != nil {
                return MetricBlock(label: "FAN", value: "--", minimumValue: "8800/8800")
            }
            // 全部风扇单行拼接（与外设电池块同构）；宽度受位数高水位约束
            let joined = MetricFormat.rpmJoined(snapshot.fans.map(\.currentRPM)) ?? "--"
            return MetricBlock(label: "FAN", value: joined, minimumValue: "8800/8800")

        case .battery:
            guard let power = snapshot.power else {
                return MetricBlock(label: "BAT", value: "--", minimumValue: "100%")
            }
            let level = MetricFormat.batteryLevel(power.batteryLevel) ?? "--"
            // 与 CPU/GPU 同构：仅当用户勾选了电池温度且合并开启时拼入电量行
            if configuration.combineTemperatures,
               enabledMetrics.contains(.batteryTemperature),
               let temp = snapshot.batteryTemperature,
               let tempStr = MetricFormat.temperature(temp, unit: configuration.temperatureUnit) {
                return MetricBlock(
                    label: "BAT",
                    value: "\(level) \(tempStr)",
                    minimumValue: Self.percentTempMinimum(unit: configuration.temperatureUnit)
                )
            }
            return MetricBlock(label: "BAT", value: level, minimumValue: "100%")
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
        // 双行堆叠：箭头承担原 NET 标签的方向语义；每行独立用绝对占位防单位切换抖动
        let first = uploadFirst ? ("↑", up) : ("↓", down)
        let second = uploadFirst ? ("↓", down) : ("↑", up)
        return MetricBlock(
            label: "NET",
            value: "\(first.0)\(first.1)",
            minimumValue: "\(first.0)000.0 MB/s",
            secondaryValue: "\(second.0)\(second.1)",
            secondaryMinimumValue: "\(second.0)000.0 MB/s"
        )
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
            pressure: block.pressure,
            secondaryValue: block.secondaryValue,
            secondaryMinimumValue: block.secondaryMinimumValue
        )
        let attachment = NSTextAttachment()
        attachment.image = image
        // 与菜单栏基线对齐
        attachment.bounds = NSRect(x: 0, y: -5.5, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// 绘制 label/value 双行块。宽度按「会话内位数高水位」同形占位预留：
    /// 只为见过的最宽形态预留（数字换 8），位数首次跨越时块宽跳变一次后稳定，
    /// 不再为可能永不出现的最坏形态（如 "100%"）常态预留空白。
    /// 自管 NSPanel 面板位置已钉死，跳变仅影响菜单栏内相邻图标瞬时挪动。
    /// 提供 secondaryValue 时切换为网速双行堆叠布局（无 label、小号字、逐行水位）。
    static func metricBlockImage(
        label: String,
        value: String,
        minimumValue reservedValue: String,
        spacing: MenuBarMetricSpacing = .standard,
        pressure: MemoryPressure? = nil,
        secondaryValue: String? = nil,
        secondaryMinimumValue: String? = nil
    ) -> NSImage {
        if let secondaryValue {
            return stackedValueImage(
                first: value,
                firstWatermarkLabel: label + "↓",
                second: secondaryValue,
                secondWatermarkLabel: label + "↑"
            )
        }

        let labelFont = NSFont.systemFont(ofSize: 6.6, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
        let sizingLabelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont]
        let sizingValueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont]

        // 统一位数高水位占位（两种间距模式一致，仅 spacer 不同）；
        // reservedValue 不再参与宽度，保留字段供内容测试断言
        let reserveCandidates = [MenuBarMetricLayout.compactReserve(label: label, value: value)]

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

    /// 以指定 backing scale 将 attributed title 光栅化为位图（设置页预览等非菜单栏场景）。
    /// 显式像素密度而非 lockFocus：后者跟随当前屏幕 scale，1x 屏上会得到 1x 位图。
    static func rasterize(_ title: NSAttributedString, backingScale: CGFloat) -> NSImage {
        let size = title.size()
        let width = max(1, ceil(size.width) + 4)
        let height = max(1, ceil(size.height) + 4)
        let pointSize = NSSize(width: width, height: height)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(width * backingScale)),
            pixelsHigh: max(1, Int(height * backingScale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // 位图缓冲不可用时退回点尺寸图像，至少保证可显示
            return NSImage(size: pointSize)
        }
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            title.draw(at: NSPoint(x: 2, y: 2))
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// 网速双行堆叠块（Stats 风格布局）：箭头固定左列 + 数值定宽列右对齐。
    /// - 箭头两行同 x 对齐，承担方向语义：下载 ↓ 蓝、上传 ↑ 红（uploadFirst 决定行序）
    /// - 数值画在恒定宽度的列内右对齐（个位对齐），数值/单位变化不改变块宽，
    ///   左侧图标不再随网速波动移动
    /// - 低于 1 KB/s（近无流量）时箭头与数值淡化，复刻参考实现的弱化语义
    /// - 块高保持 21 与其他指标对齐
    private static func stackedValueImage(
        first: String,
        firstWatermarkLabel: String,
        second: String,
        secondWatermarkLabel: String
    ) -> NSImage {
        _ = firstWatermarkLabel
        _ = secondWatermarkLabel

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)

        // 箭头 = 行首字符；数值 = 其余部分（"↓1.4 MB/s" → "1.4 MB/s"）
        func split(_ row: String) -> (arrow: String, value: String, isIdle: Bool) {
            let arrow = String(row.prefix(1))
            let value = String(row.dropFirst())
            return (arrow, value, value.contains(" B/s"))
        }
        let firstRow = split(first)
        let secondRow = split(second)

        // 定宽布局：箭头列 8 + 间隙 2 + 数值列 45（MetricFormat ≥10 无小数，
        // 全段最宽形态 "888 KB/s" ≈ 43.7pt）
        let arrowColumn: CGFloat = 8
        let valueColumn: CGFloat = 45
        let width = ceil(arrowColumn + 2 + valueColumn)
        let height: CGFloat = 21

        func drawRow(_ row: (arrow: String, value: String, isIdle: Bool), baselineY: CGFloat) {
            let arrowColor: NSColor = row.isIdle ? .secondaryLabelColor : arrowTint(row.arrow)
            let valueColor: NSColor = row.isIdle ? .secondaryLabelColor : .labelColor

            (row.arrow as NSString).draw(
                at: NSPoint(x: 0, y: baselineY),
                withAttributes: [.font: font, .foregroundColor: arrowColor]
            )
            let valueWidth = (row.value as NSString).size(withAttributes: [.font: font]).width
            (row.value as NSString).draw(
                at: NSPoint(x: width - valueWidth, y: baselineY),
                withAttributes: [.font: font, .foregroundColor: valueColor]
            )
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            // 基线经 2x 位图像素校准：两行内容垂直中心与 label/value 块内容中心一致
            drawRow(firstRow, baselineY: 9.5)
            drawRow(secondRow, baselineY: 0.4)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 方向箭头着色：下载蓝、上传红（对齐参考实现的 input/output 语义）
    private static func arrowTint(_ arrow: String) -> NSColor {
        arrow == "↓" ? .systemBlue : .systemRed
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
