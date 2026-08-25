import Charts
import SwiftUI

/// 趋势面积图（对齐 TokenTracker `UsageTrendChart`）：AreaMark 渐变 + LineMark 平滑插值，
/// 区头右侧自带 日/周/月/总计 切换器；hover 画 RuleMark + PointMark 并把该点数值内联到区头
/// （NSPopover 内无法悬浮 tooltip）。空数据时显示占位块。
struct TokenUsageTrendChartView: View {
    let points: [UsageTrendPoint]
    @Binding var period: TokenTrendPeriod
    let strings: Strings
    var onPeriodChange: (TokenTrendPeriod) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    @State private var hovered: UsageTrendPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader
            if points.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
                    .frame(height: 140)
                    .overlay(
                        Text(strings.tokenEmptyHint)
                            .font(Theme.Stats.font10Regular)
                            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                    )
            } else {
                chart
            }
        }
        .padding(12)
        .omniCardStyle()
        .onChange(of: period) { _, _ in hovered = nil }
    }

    // MARK: - 区头

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 8, height: 8)
            Text(strings.tokenTrendTitle)
                .font(Theme.Stats.font13SemiBold)
                .foregroundColor(Theme.Stats.text1)
            Spacer()
            if let hovered {
                Text(
                    "\(hovered.date.formatted(xAxisFormat)) - \(TokenUsageFormat.compactTokens(hovered.tokens)) \(strings.tokenUnit)"
                )
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
                .transition(.opacity)
            }
            periodPicker
        }
    }

    // MARK: - 周期切换

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TokenTrendPeriod.allCases) { item in
                Button {
                    onPeriodChange(item)
                } label: {
                    Text(item.label(strings))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(
                            item == period
                                ? (colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                                : (colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            if item == period {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Theme.Stats.cardBackground)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == period ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
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
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let plotFrame = proxy.plotFrame {
                                let plotOrigin = geo[plotFrame].origin
                                if let date: Date = proxy.value(atX: location.x - plotOrigin.x) {
                                    hovered = nearestPoint(to: date)
                                }
                            }
                        case .ended:
                            hovered = nil
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
                        Text(TokenUsageFormat.compactTokens(intValue))
                    }
                }
            }
        }
        .frame(height: 140)
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
