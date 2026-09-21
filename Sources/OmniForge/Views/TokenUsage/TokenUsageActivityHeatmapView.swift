import SwiftUI

/// 活跃度年度热力图：月标签行 + 周列 × 7 行网格 + 「少/多」图例 + 跟随鼠标的悬浮气泡。
///
/// hover 某格时气泡显示「M月d日 · X tokens」（挂在鼠标上方，贴近顶部翻到下方），
/// 区头恒显「N 活跃日」。气泡挂在组件顶层 overlay，避开横向 ScrollView 的内容裁剪。
/// 无数据时（`heatmap == nil`）显示占位块。
struct TokenUsageActivityHeatmapView: View {
    let heatmap: UsageActivityHeatmap?
    var numberStyle: TokenUsageNumberStyle = .western
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    private let cellSize: CGFloat = 11
    private let spacing: CGFloat = 3

    /// 悬浮位置上报用的命名坐标系（相对本组件整体 bounds）。
    private static let spaceName = "activity-heatmap"

    /// 五档色阶（0 = 空 / 1...4 = 数据强度），用主强调蓝。
    private static let levelColors: [Color] = [
        Theme.Stats.cpu.opacity(0.10),
        Theme.Stats.cpu.opacity(0.25),
        Theme.Stats.cpu.opacity(0.50),
        Theme.Stats.cpu.opacity(0.75),
        Theme.Stats.cpu,
    ]

    @State private var hovered: HoveredCellKey?
    /// 光标在本组件内的位置（驱动气泡跟随鼠标）。
    @State private var hoverLocation: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader
            if let heatmap, !heatmap.weeks.isEmpty {
                grid(heatmap)
                legend
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
                    .frame(height: 7 * (cellSize + spacing) - spacing)
            }
        }
        .coordinateSpace(name: Self.spaceName)
        .overlay {
            if let heatmap, let cell = hoveredCell(in: heatmap), let hoverLocation {
                hoverBubble(cell, location: hoverLocation)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    // MARK: - 区头

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 6, height: 6)
            Text(strings.tokenActivityTitle)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
            Spacer()
            if let heatmap {
                Text(String(format: strings.tokenSummaryActiveDaysFormat, heatmap.activeDays))
                    .font(Theme.Stats.font10Regular)
                    .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
            }
        }
    }

    // MARK: - 网格

    private func grid(_ heatmap: UsageActivityHeatmap) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                let labels = monthLabels(heatmap)
                VStack(alignment: .leading, spacing: spacing) {
                    // 月标签锚行（一年网格没有时间轴不可读）。
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                            Text(label ?? "")
                                .font(Theme.Stats.font10Regular)
                                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                                .fixedSize()
                                .frame(width: cellSize, height: 10, alignment: .leading)
                        }
                    }
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(heatmap.weeks.enumerated()), id: \.offset) { weekIdx, week in
                            VStack(spacing: spacing) {
                                ForEach(0..<7, id: \.self) { dayIdx in
                                    cellView(week: week, weekIdx: weekIdx, dayIdx: dayIdx)
                                }
                            }
                            .id(weekIdx)
                        }
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(heatmap.weeks.count - 1, anchor: .trailing)
            }
        }
    }

    @ViewBuilder
    private func cellView(week: [UsageActivityHeatmapCell?], weekIdx: Int, dayIdx: Int) -> some View {
        let cell = dayIdx < week.count ? week[dayIdx] : nil
        let level = cell?.level ?? 0
        let key = HoveredCellKey(week: weekIdx, day: dayIdx)
        let isHovered = cell != nil && hovered == key
        RoundedRectangle(cornerRadius: 2)
            .fill(Self.levelColors[min(max(level, 0), Self.levelColors.count - 1)])
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.55 : 0), lineWidth: 1)
            )
            .onContinuousHover(coordinateSpace: .named(Self.spaceName)) { phase in
                switch phase {
                case .active(let location):
                    guard cell != nil else { return }
                    hovered = key
                    hoverLocation = location
                case .ended:
                    if hovered == key { hovered = nil }
                    hoverLocation = nil
                }
            }
    }

    // MARK: - 图例

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text(strings.tokenActivityLegendLess)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Self.levelColors[level])
                    .frame(width: 8, height: 8)
            }
            Text(strings.tokenActivityLegendMore)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
        }
    }

    // MARK: - 月标签 / hover

    /// 每列一个槽位：月份变化的第一列放本地化月名，其余 nil。
    /// 标签溢出 11pt 槽向右展开（月份至少相隔 4 列，不会碰撞）。
    private func monthLabels(_ heatmap: UsageActivityHeatmap) -> [String?] {
        var labels: [String?] = []
        var lastMonth: Int?
        for week in heatmap.weeks {
            guard let firstDay = week.compactMap({ $0?.dayStart }).first else {
                labels.append(nil)
                continue
            }
            let month = Calendar.current.component(.month, from: firstDay)
            if month != lastMonth {
                labels.append(Self.monthFormatter.string(from: firstDay))
                lastMonth = month
            } else {
                labels.append(nil)
            }
        }
        return labels
    }

    private func hoveredCell(in heatmap: UsageActivityHeatmap) -> UsageActivityHeatmapCell? {
        guard let key = hovered,
              key.week >= 0, key.week < heatmap.weeks.count,
              key.day >= 0, key.day < heatmap.weeks[key.week].count
        else { return nil }
        return heatmap.weeks[key.week][key.day]
    }

    // MARK: - 悬浮气泡

    /// 跟随鼠标的数值气泡：主行 token 数、次行 M月d日。位置来自命名坐标系上报，
    /// 挂在组件顶层 overlay（网格的横向 ScrollView 会裁剪越界内容，气泡不能放格子里）。
    private func hoverBubble(_ cell: UsageActivityHeatmapCell, location: CGPoint) -> some View {
        GeometryReader { geo in
            let placed = CursorBubbleLocator.anchor(location: location, in: geo.size)
            CursorBubbleAnchor(anchor: placed.anchor, alignment: placed.alignment) {
                SparklineBubbleShell(colorScheme: colorScheme) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            "\(TokenUsageFormat.compactTokens(cell.totalTokens, style: numberStyle)) \(strings.tokenUnit)"
                        )
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        Text(Self.dayFormatter.string(from: cell.dayStart))
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}

private struct HoveredCellKey: Equatable {
    let week: Int
    let day: Int
}
