import SwiftUI

/// 用量汇总指标区（今日 / 7天 / 30天 / 总计）：平面四列等宽，无卡片底，
/// 层级对齐监控指标列（标题 → 大数字 → 副标），列间以固定内边距分隔。
///
/// 窗口固定（今日/7天/30天/总计），不随趋势周期切换变化；副标为 token 口径可达指标
/// （今日 = 会话数；7天/总计 = 活跃日；30天 = 平均每活跃日，SPEC 2.1）。
struct TokenUsageSummaryCardsView: View {
    let cards: UsageSummaryCards
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            statColumn(
                title: strings.tokenSummaryToday,
                value: TokenUsageFormat.compactTokens(cards.todayTokens),
                subtitle: String(format: strings.tokenSummaryConversationsFormat, cards.todayConversations)
            )
            statColumn(
                title: strings.tokenSummarySevenDays,
                value: TokenUsageFormat.compactTokens(cards.last7dTokens),
                subtitle: String(format: strings.tokenSummaryActiveDaysFormat, cards.last7dActiveDays)
            )
            statColumn(
                title: strings.tokenSummaryThirtyDays,
                value: TokenUsageFormat.compactTokens(cards.last30dTokens),
                subtitle: String(
                    format: strings.tokenSummaryAvgPerDayFormat,
                    TokenUsageFormat.compactTokens(cards.last30dAvgPerActiveDay)
                )
            )
            statColumn(
                title: strings.tokenSummaryTotal,
                value: TokenUsageFormat.compactTokens(cards.totalTokens),
                subtitle: String(format: strings.tokenSummaryActiveDaysFormat, cards.totalActiveDays)
            )
        }
    }

    /// 指标单列：标题（12 semibold 次色）→ 大数字（20 semibold mono）→ 副标（10 次色）。
    /// 列内边距对齐监控指标列节奏（左 16 / 右 12 / 上下 14）。
    private func statColumn(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 12))
        // idealWidth 置 0 + maxWidth .infinity：各列严格等宽（与监控三列指标同一手法）
        .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
