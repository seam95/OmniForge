import Charts
import SwiftUI

/// 趋势面积图：AreaMark 渐变 + LineMark 平滑插值，
/// 区头右侧自带 日/周/月/总计 切换器；hover 画 RuleMark + PointMark，
/// 数值气泡跟随鼠标显示（`CursorBubbleAnchor` 悬挂，贴近顶部时翻到下方）。空数据时显示占位块。
struct TokenUsageTrendChartView: View {
    let points: [UsageTrendPoint]
    @Binding var period: TokenTrendPeriod
    var numberStyle: TokenUsageNumberStyle = .western
    let strings: Strings
    var onPeriodChange: (TokenTrendPeriod) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    @State private var hovered: UsageTrendPoint?
    /// 光标在图表内的位置（驱动气泡跟随鼠标）。
    @State private var hoverLocation: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader
            if points.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
                    .frame(height: 140)
                    .overlay(
                        Text(strings.tokenUsageEmptyHint)
                            .font(Theme.Stats.font10Regular)
                            .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                    )
            } else {
                chart
            }
        }
        .onChange(of: period) { _, _ in
            hovered = nil
            hoverLocation = nil
        }
    }

    // MARK: - 区头

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 6, height: 6)
            Text(strings.tokenTrendTitle)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
            Spacer()
            TokenUsageInlinePicker(
                items: TokenTrendPeriod.allCases,
                selection: $period,
                label: { $0.label(strings) },
                onChange: onPeriodChange
            )
        }
    }

    // MARK: - 图表

    private var chart: some View {
        let interpolation: InterpolationMethod = period == .day ? .monotone : .catmullRom
        return Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.Stats.cpu.opacity(0.32), Theme.Stats.cpu.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(interpolation)

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(Theme.Stats.cpu)
                .interpolationMethod(interpolation)
            }

            if let hovered {
                RuleMark(x: .value("Date", hovered.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Date", hovered.date),
                    y: .value("Tokens", hovered.tokens)
                )
                .foregroundStyle(Theme.Stats.cpu)
                .symbolSize(32)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hoverLocation = location
                                if let plotFrame = proxy.plotFrame {
                                    let plotOrigin = geo[plotFrame].origin
                                    if let date: Date = proxy.value(atX: location.x - plotOrigin.x) {
                                        hovered = nearestPoint(to: date)
                                    }
                                }
                            case .ended:
                                hovered = nil
                                hoverLocation = nil
                            }
                        }
                    if let hovered, let hoverLocation {
                        hoverBubble(hovered, location: hoverLocation, in: geo.size)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride, count: xStrideCount)) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text(TokenUsageFormat.compactTokens(intValue, style: numberStyle))
                    }
                }
            }
        }
        .frame(height: 140)
    }

    // MARK: - 悬浮气泡

    /// 跟随鼠标的数值气泡：主行 token 数、次行采样点日期（与图内定位用同一套轴格式）。
    private func hoverBubble(_ point: UsageTrendPoint, location: CGPoint, in size: CGSize) -> some View {
        let placed = CursorBubbleLocator.anchor(location: location, in: size)
        return CursorBubbleAnchor(anchor: placed.anchor, alignment: placed.alignment) {
            SparklineBubbleShell(colorScheme: colorScheme) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        "\(TokenUsageFormat.compactTokens(point.tokens, style: numberStyle)) \(strings.tokenUnit)"
                    )
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    Text(point.date.formatted(xAxisFormat))
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var xStride: Calendar.Component {
        switch period {
        case .day: return .hour
        case .week, .month: return .day
        case .total: return .month
        }
    }

    private var xStrideCount: Int {
        switch period {
        case .day: return 4
        case .week: return 1
        case .month: return 7
        case .total: return 4
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch period {
        case .day: return .dateTime.hour()
        case .week, .month: return .dateTime.month(.abbreviated).day()
        case .total: return .dateTime.year(.twoDigits).month(.abbreviated)
        }
    }

    private func nearestPoint(to date: Date) -> UsageTrendPoint? {
        points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }
}

/// 趋势周期显示名（日 / 周 / 月 / 总计）。
extension TokenTrendPeriod {
    func label(_ strings: Strings) -> String {
        switch self {
        case .day: return strings.tokenTrendPeriodDay
        case .week: return strings.tokenTrendPeriodWeek
        case .month: return strings.tokenTrendPeriodMonth
        case .total: return strings.tokenTrendPeriodTotal
        }
    }
}
