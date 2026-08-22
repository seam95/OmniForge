import SwiftUI

/// 趋势/仪表/进度通用卡片外壳 — 彩色圆点 + 灰色小标题 + 大号值 + 可视化 + 灰色 caption。
/// 可视化变体：`.sparkline`（CPU/GPU，值与折线同行）、`.semiGauge`（内存，值叠放在弧内）、`.progressBar`（电池）。
enum MonitorTrendVisualization: Equatable {
    case sparkline([Double])
    case semiGauge(progress: Double)
    case progressBar(progress: Double)
}

struct MonitorTrendCard: View {
    let model: MonitorCardModel
    let accent: Color
    let visualization: MonitorTrendVisualization
    let height: CGFloat
    /// nil = 不可点击（电池卡）；非 nil = 整卡按钮 + 悬浮 chevron。
    let action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { cardContent }
                    .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var cardContent: some View {
        MonitorDashboardCardChrome(accent: accent, height: height, isInteractive: action != nil) {
            VStack(alignment: .leading, spacing: 4) {
                header

                if let issueText = model.issueText {
                    Text(issueText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                } else {
                    switch visualization {
                    case .semiGauge(let progress):
                        // 值 + caption 叠放在半圆弧内
                        ZStack {
                            SemiCircleGaugeView(progress: progress, accent: accent)
                            VStack(spacing: 2) {
                                Text(model.primaryText)
                                    .font(.title3.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                if let caption = model.secondaryText {
                                    Text(caption)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .offset(y: -6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .sparkline(let values):
                        // 大号值与趋势折线同行，折线占剩余横向空间
                        HStack(alignment: .center, spacing: 10) {
                            primaryValue
                            SparklineView(values: values, color: accent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        captionView
                    case .progressBar(let progress):
                        primaryValue
                        VStack(spacing: 3) {
                            Spacer(minLength: 0)
                            MetricBar(value: progress, warning: 101, critical: 101, tint: accent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        captionView
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var primaryValue: some View {
        Text(model.primaryText)
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var captionView: some View {
        if let caption = model.secondaryText {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)

            Text(model.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if model.showsLiveDot {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }

            if let badgeText = model.badgeText {
                Text(badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
    }
}
