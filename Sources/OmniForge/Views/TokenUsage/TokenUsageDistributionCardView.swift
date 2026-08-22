import SwiftUI

/// 分布卡：「按模型」/「按 Provider」两区，`#E5E5EA`（`Theme.Stats.separator`）分隔。
///
/// 每行 = 名称 11 + `MetricBar` + 等宽右对齐 tokens（UI 稿）：
/// 按模型统一蓝色（`Theme.Stats.cpu`），按 Provider 用各家模块色；
/// 条长为该行占本区最大行的比例。仅展示名称与 token 计数（隐私红线，SPEC 2.6）。
struct TokenUsageDistributionCardView: View {
    let distribution: UsageDistribution
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: strings.tokenByModelTitle)
            rows(
                distribution.byModel,
                maxTokens: maxTokens(distribution.byModel),
                tint: { _ in Theme.Stats.cpu }
            )
            Rectangle()
                .fill(colorScheme == .light ? Theme.Stats.separator : Color.white.opacity(0.12))
                .frame(height: 1)
            sectionHeader(title: strings.tokenByProviderTitle)
            rows(
                distribution.byProvider,
                maxTokens: maxTokens(distribution.byProvider),
                tint: { entry in entry.provider?.accentColor ?? Theme.Stats.cpu }
            )
        }
        .padding(12)
        .omniCardStyle()
    }

    // MARK: - 区域头

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 8, height: 8)
            Text(title)
                .font(Theme.Stats.font13SemiBold)
                .foregroundColor(Theme.Stats.text1)
        }
    }

    // MARK: - 行

    private func rows(
        _ entries: [UsageDistributionEntry],
        maxTokens: Int,
        tint: @escaping (UsageDistributionEntry) -> Color
    ) -> some View {
        VStack(spacing: 6) {
            ForEach(entries) { entry in
                row(entry, maxTokens: maxTokens, tint: tint(entry))
            }
        }
    }

    private func row(_ entry: UsageDistributionEntry, maxTokens: Int, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(entry.label)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96, alignment: .leading)
            MetricBar(
                value: Double(entry.totalTokens) / Double(max(maxTokens, 1)),
                warning: 101,
                critical: 102,
                tint: tint
            )
            Text(TokenUsageFormat.tokens(entry.totalTokens))
                .font(Theme.Stats.font11Regular)
                .monospacedDigit()
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : .primary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func maxTokens(_ entries: [UsageDistributionEntry]) -> Int {
        entries.map(\.totalTokens).max() ?? 0
    }
}
