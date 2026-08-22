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
                        // 内存卡片：居中半圆仪表弧 + 中心大号百分比 + 底部副文案
                        VStack(spacing: 2) {
                            ZStack {
                                SemiCircleGaugeView(progress: progress, accent: accent, lineWidth: 7)
                                    .frame(height: 48)
                                    .padding(.top, 4)

                                Text(model.primaryText)
                                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .offset(y: 12)
                            }
                            .frame(maxWidth: .infinity)

                            Spacer(minLength: 2)

                            captionView
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    case .sparkline(let values):
                        // CPU / GPU 卡片：大号数值居上，面积折线图居中全宽，副文案居底
                        VStack(alignment: .leading, spacing: 3) {
                            primaryValue

                            SparklineView(values: values, color: accent, lineWidth: 1.8, fillHeight: 0.35)
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: .infinity)

                            captionView
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                    case .progressBar(let progress):
                        // 电池卡片：大号数值居上，胶囊进度条居中，副文案居底
                        VStack(alignment: .leading, spacing: 6) {
                            primaryValue

                            MetricBar(value: progress, warning: 101, critical: 101, tint: accent)
                                .frame(height: 5)
                                .padding(.top, 2)

                            Spacer(minLength: 2)

                            captionView
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var primaryValue: some View {
        Text(model.primaryText)
            .font(.system(size: 22, weight: .bold).monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    @ViewBuilder
    private var captionView: some View {
        if let caption = model.secondaryText {
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 8, height: 8)

            Text(model.title)
                .font(.system(size: 13, weight: .medium))
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
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
    }
}
