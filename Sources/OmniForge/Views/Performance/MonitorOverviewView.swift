import SwiftUI

/// 监控 overview 平面布局配色：浅色走 Stats 规范，深色走系统语义色。
enum MonitorOverviewPalette {
    static func primary(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Theme.Stats.text1 : .primary
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Theme.Stats.text2 : .secondary
    }

    static func auxiliary(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Theme.Stats.text3 : .secondary
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Theme.Stats.hairline : Color.primary.opacity(0.1)
    }

    static func hoverFill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.08 : 0.04)
    }
}

/// Overview page（平面分区布局）：设备摘要 Header → CPU|GPU|内存三栏 → 网络 → 磁盘 → 电池。
/// 无卡片：浅色白底 + 发丝线分区；点击导航（三栏/网络 → 排名，磁盘 → 详情）保留。
struct MonitorOverviewView: View {
    let snapshot: SystemSnapshot
    let history: MetricHistory
    let configuration: MonitorConfiguration
    let strings: Strings
    let deviceSummary: DeviceSummary
    let onSelectRankable: (ProcessMetricKind) -> Void
    let onSelectDiskDetail: () -> Void
    let onRefresh: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var models: [MonitorCardModel] {
        MonitorCardModelBuilder.models(
            snapshot: snapshot,
            configuration: configuration,
            strings: strings,
            temperatureUnit: configuration.temperatureUnit,
            history: history
        )
    }

    private var sections: [MonitorOverviewSection] {
        MonitorOverviewSectionPlanner.sections(from: models)
    }

    private var statusText: String {
        snapshot.issues.isEmpty ? strings.monitorStatusNormal : strings.monitorStatusIssue
    }

    private var hasIssues: Bool {
        !snapshot.issues.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !sections.isEmpty {
                hairline

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        hairline
                    }
                    sectionView(section)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(colorScheme == .light ? Color.white : Color.clear)
    }

    private var hairline: some View {
        Rectangle()
            .fill(MonitorOverviewPalette.hairline(colorScheme))
            .frame(height: 1)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(deviceSummary.hostName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 8)

                statusPill
            }

            HStack(alignment: .center) {
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // 负 padding 抵消 IconButton 的 24pt 点击框，让图标视觉贴合行高与右缘
                IconButton(
                    systemImage: "arrow.clockwise",
                    tint: MonitorOverviewPalette.auxiliary(colorScheme),
                    help: strings.monitorRefreshAll,
                    action: onRefresh
                )
                .padding(.trailing, -6)
                .padding(.vertical, -4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitleText: String? {
        var parts: [String] = []
        if let os = deviceSummary.osVersionText, !os.isEmpty {
            parts.append(os)
        }
        if let uptime = deviceSummary.uptimeText, !uptime.isEmpty {
            parts.append("\(strings.monitorUptimePrefix) \(uptime)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \(strings.monitorSubtitleSeparator) ")
    }

    private var statusPill: some View {
        let tintColor = hasIssues ? Theme.Stats.up : Theme.Stats.statusNormal
        return HStack(spacing: 5) {
            Circle()
                .fill(tintColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tintColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .light ? Color.white : Color.white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: MonitorOverviewSection) -> some View {
        switch section {
        case let .triple(models):
            HStack(alignment: .top, spacing: 0) {
                ForEach(models) { model in
                    MonitorMetricColumn(
                        model: model,
                        accent: MonitorCardAccent.color(for: model.id),
                        action: model.processMetricKind.map { kind in
                            { onSelectRankable(kind) }
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // 栏内水平 12 + hover 底 4 = 设计稿栏内 16；整区 4 补齐首栏 20 / 末栏 20
            .padding(.horizontal, 4)
            .padding(.vertical, 16)

        case let .network(model):
            MonitorNetworkSection(
                model: model,
                strings: strings,
                action: { onSelectRankable(.network) }
            )

        case let .disk(model):
            MonitorDiskSection(
                model: model,
                strings: strings,
                action: onSelectDiskDetail
            )

        case let .battery(model):
            MonitorBatterySection(model: model)
        }
    }
}

/// 区块公共样式：6pt 彩色方块标签、悬浮底、字号梯度。
private enum MonitorSectionStyle {
    static let labelFont = Font.system(size: 12, weight: .semibold)
    static let labelTracking: CGFloat = 1
    static let squareSize: CGFloat = 6

    static func square(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: squareSize, height: squareSize)
    }
}

/// 可点区块外壳：内容 + hover 浅灰圆角底（无 chevron，对齐平面视觉）。
/// hover 底向外扩 4pt（内容 padding 4），调用方据此把设计稿边距减 4 保持视觉位置。
private struct MonitorTappableSection<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(isHovered ? MonitorOverviewPalette.hoverFill(colorScheme) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
    }
}

/// 三栏指标列：标签 + 温度标记 → 28pt 大数字 → 36pt 细线折线 → 明细（仅 CPU）。
private struct MonitorMetricColumn: View {
    let model: MonitorCardModel
    let accent: Color
    /// nil 不可点（当前三栏均可点进排名，保留口子）
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let action {
                MonitorTappableSection(action: action) { column }
            } else {
                column
            }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title)
                    .font(MonitorSectionStyle.labelFont)
                    .tracking(MonitorSectionStyle.labelTracking)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let temperature = model.temperatureText {
                    Text(temperature)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }

            if let issue = model.issueText {
                Text(issue)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Theme.Stats.up)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text(model.primaryText)
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .tracking(-0.8)
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                SparklineView(
                    values: model.trend ?? [],
                    color: accent,
                    lineWidth: 1.3,
                    fillHeight: 0,
                    endDotRadius: 2
                )
                .frame(height: 36)

                    // 明细行仅 CPU（系统/用户拆分）有内容，其余栏留空保持顶部对齐
                if model.id == .cpu, let detail = model.secondaryText {
                    Text(detail)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 网络区：速率行（↓ 下行主色大号 / ↑ 上行次要）→ 双线走势 44pt → 累计行。
private struct MonitorNetworkSection: View {
    let model: MonitorCardModel
    let strings: Strings
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var downText: String {
        model.chipTexts.indices.contains(0) ? model.chipTexts[0] : "--"
    }

    private var upText: String {
        model.chipTexts.indices.contains(1) ? model.chipTexts[1] : "--"
    }

    var body: some View {
        MonitorTappableSection(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        MonitorSectionStyle.square(Theme.Stats.down)
                        Text(model.title)
                            .font(MonitorSectionStyle.labelFont)
                            .tracking(MonitorSectionStyle.labelTracking)
                            .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Stats.down)
                        Text(downText)
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                            .lineLimit(1)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Stats.up)
                        Text(upText)
                            .font(.system(size: 15, weight: .regular).monospacedDigit())
                            .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                            .lineLimit(1)
                    }
                }

                if let issue = model.issueText {
                    Text(issue)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(Theme.Stats.up)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    DualSparklineView(
                        downValues: model.trend ?? [],
                        upValues: model.secondaryTrend ?? []
                    )
                    .frame(height: 44)

                    if let caption = model.secondaryText {
                        Text(caption)
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// 磁盘区：标签行（右侧「已用 x GB」）→ IO 行（读主色 / 写次要）。
private struct MonitorDiskSection: View {
    let model: MonitorCardModel
    let strings: Strings
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var readText: String {
        model.chipTexts.indices.contains(0) ? model.chipTexts[0] : "--"
    }

    private var writeText: String {
        model.chipTexts.indices.contains(1) ? model.chipTexts[1] : "--"
    }

    var body: some View {
        MonitorTappableSection(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    MonitorSectionStyle.square(MonitorCardAccent.color(for: .disk))
                    Text(model.title)
                        .font(MonitorSectionStyle.labelFont)
                        .tracking(MonitorSectionStyle.labelTracking)
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let badge = model.badgeText {
                        Text(badge)
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                            .lineLimit(1)
                    }
                }

                if let issue = model.issueText {
                    Text(issue)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(Theme.Stats.up)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    HStack(spacing: 20) {
                        ioRow(
                            systemImage: "arrow.down",
                            iconOpacity: 1,
                            text: "\(strings.monitorMetricRead) \(readText)",
                            font: .system(size: 14, weight: .medium),
                            color: MonitorOverviewPalette.primary(colorScheme)
                        )
                        ioRow(
                            systemImage: "arrow.up",
                            iconOpacity: 0.6,
                            text: "\(strings.monitorMetricWrite) \(writeText)",
                            font: .system(size: 14, weight: .regular),
                            color: MonitorOverviewPalette.secondary(colorScheme)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func ioRow(
        systemImage: String,
        iconOpacity: Double,
        text: String,
        font: Font,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MonitorCardAccent.color(for: .disk).opacity(iconOpacity))
            Text(text)
                .font(font.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// 电池区：标签行（右侧「电量 · 温度」）→ 4pt 进度条 → 明细行。不可点。
private struct MonitorBatterySection: View {
    let model: MonitorCardModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                MonitorSectionStyle.square(MonitorCardAccent.color(for: .battery))
                Text(model.title)
                    .font(MonitorSectionStyle.labelFont)
                    .tracking(MonitorSectionStyle.labelTracking)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(model.primaryText)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    .lineLimit(1)
            }

            if let issue = model.issueText {
                Text(issue)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Theme.Stats.up)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                if let progress = model.progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.12))
                            Capsule(style: .continuous)
                                .fill(MonitorCardAccent.barTint(for: .battery, progress: progress))
                                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 4)
                }

                if let caption = model.secondaryText {
                    Text(caption)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}
