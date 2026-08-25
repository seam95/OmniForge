import SwiftUI

/// 顶部 4 张汇总卡（今日 / 7天 / 30天 / 总计）— 对齐 TokenTracker `SummaryCardsView`。
///
/// 窗口固定（今日/7天/30天/总计），不随趋势周期切换变化；副标为 token 口径可达指标
/// （今日 = 会话数；7天/总计 = 活跃日；30天 = 平均每活跃日，SPEC 2.1）。
struct TokenUsageSummaryCardsView: View {
    let cards: UsageSummaryCards
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            statCard(
                title: strings.tokenSummaryToday,
                value: TokenUsageFormat.compactTokens(cards.todayTokens),
                subtitle: String(format: strings.tokenSummaryConversationsFormat, cards.todayConversations)
            )
            statCard(
                title: strings.tokenSummarySevenDays,
                value: TokenUsageFormat.compactTokens(cards.last7dTokens),
                subtitle: String(format: strings.tokenSummaryActiveDaysFormat, cards.last7dActiveDays)
            )
            statCard(
                title: strings.tokenSummaryThirtyDays,
                value: TokenUsageFormat.compactTokens(cards.last30dTokens),
                subtitle: String(
                    format: strings.tokenSummaryAvgPerDayFormat,
                    TokenUsageFormat.compactTokens(cards.last30dAvgPerActiveDay)
                )
            )
            statCard(
                title: strings.tokenSummaryTotal,
                value: TokenUsageFormat.compactTokens(cards.totalTokens),
                subtitle: String(format: strings.tokenSummaryActiveDaysFormat, cards.totalActiveDays)
            )
        }
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
            Text(subtitle)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            colorScheme == .light ? Theme.Stats.separator : Color.white.opacity(0.12),
                            lineWidth: 0.5
                        )
                )
        )
        .accessibilityElement(children: .combine)
    }
}
