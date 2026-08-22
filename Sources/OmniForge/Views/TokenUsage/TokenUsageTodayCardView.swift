import SwiftUI

/// 今日/本周/本月用量卡：24Bold 等宽大数值（周期总量）+ 副文案（tokens · N 会话 · M 家已配置）
/// + 趋势 Sparkline（周期内逐日，蓝渐变面积）+ 趋势 caption（峰值）。
///
/// 回填中时大数值位显示「正在统计历史用量…」，不阻塞（SPEC 4.2 / 4.6）；
/// 周期切换后大数值/副文案/趋势/分布全部按周期重算（#05，周期选择器只作用于用量区块）。
struct TokenUsageTodayCardView: View {
    let overview: TokenUsageOverview?
    let backfilling: Bool
    /// 副文案「M 家已配置」的家数（聚合口径 = 有数据 provider 数；单家切选 = 1）。
    let providerCount: Int
    let period: TokenUsagePeriod
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bigValue
            if let overview {
                subtitle(overview)
                trendChart(overview)
                trendCaption(overview)
            }
        }
        .padding(12)
        .omniCardStyle()
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 8, height: 8)
            Text(period.cardTitle(strings))
                .font(Theme.Stats.font13SemiBold)
                .foregroundColor(Theme.Stats.text1)
            Spacer()
        }
    }

    // MARK: - 数值位

    @ViewBuilder
    private var bigValue: some View {
        if backfilling {
            Text(strings.tokenBackfilling)
                .font(Theme.Stats.font24Bold)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : .primary)
        } else {
            Text(TokenUsageFormat.tokens(overview?.totalTokens ?? 0))
                .font(Theme.Stats.font24Bold)
                .monospacedDigit()
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : .primary)
        }
    }

    // MARK: - 副文案 / 趋势 / caption

    private func subtitle(_ overview: TokenUsageOverview) -> some View {
        Text(
            String(
                format: strings.tokenUsageSubtitleFormat,
                overview.conversations,
                providerCount
            )
        )
        .font(Theme.Stats.font10Regular)
        .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : .secondary)
    }

    private func trendChart(_ overview: TokenUsageOverview) -> some View {
        let values = overview.daily.map { Double($0.totalTokens) }
        let maxValue = max(values.max() ?? 0, 1)
        return SparklineView(
            values: values,
            color: Theme.Stats.cpu,
            domain: 0...maxValue
        )
        .frame(height: 44)
    }

    @ViewBuilder
    private func trendCaption(_ overview: TokenUsageOverview) -> some View {
        if let peak = overview.peak, peak.totalTokens > 0 {
            Text(
                String(
                    format: period.trendCaptionFormat(strings),
                    TokenUsageFormat.tokens(peak.totalTokens),
                    TokenUsageFormat.weekdayName(for: peak.dayStart, strings: strings)
                )
            )
            .font(Theme.Stats.font10Regular)
            .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : .secondary)
        }
    }
}
