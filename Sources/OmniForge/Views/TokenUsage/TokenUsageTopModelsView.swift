import SwiftUI

/// 模型 Top 列表（对齐 TokenTracker `TopModelsView`）：彩色圆点（按名次五色循环）+
/// 名称 + tokens 缩写 + 1 位小数占比% + 行底 12% 比例条（占比可视化）。
/// 仅按模型聚合（SPEC 2.4）；空列表时整块不显示。
struct TokenUsageTopModelsView: View {
    let models: [UsageTopModelEntry]
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    /// 名次圆点五色循环（对齐 TokenTracker modelDotPalette 气质）。
    private static let dotPalette: [Color] = [
        Color(.sRGB, red: 0.35, green: 0.55, blue: 0.95, opacity: 1.0),  // soft blue
        Color(.sRGB, red: 0.60, green: 0.45, blue: 0.90, opacity: 1.0),  // lavender
        Color(.sRGB, red: 0.30, green: 0.72, blue: 0.65, opacity: 1.0),  // teal
        Color(.sRGB, red: 0.90, green: 0.55, blue: 0.35, opacity: 1.0),  // warm amber
        Color(.sRGB, red: 0.70, green: 0.50, blue: 0.75, opacity: 1.0),  // muted plum
    ]

    var body: some View {
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    row(model, index: index)
                }
            }
            .padding(12)
            .omniCardStyle()
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 8, height: 8)
            Text(strings.tokenTopModelsTitle)
                .font(Theme.Stats.font13SemiBold)
                .foregroundColor(Theme.Stats.text1)
            Spacer()
        }
    }

    private func row(_ model: UsageTopModelEntry, index: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.dotPalette[index % Self.dotPalette.count])
                .frame(width: 5, height: 5)
            Text(model.name)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.name)
            Spacer(minLength: 4)
            Text(TokenUsageFormat.compactTokens(model.tokens))
                .font(Theme.Stats.font11Regular)
                .monospacedDigit()
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text2 : Color.secondary)
            Text(TokenUsageFormat.percentOneDecimal(model.percent))
                .font(Theme.Stats.font11Regular)
                .monospacedDigit()
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        // 按占比铺底条，让占比可视化为比例而非只有数字列。
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.dotPalette[index % Self.dotPalette.count].opacity(0.12))
                    .frame(
                        width: geo.size.width * CGFloat(min(max(model.percent / 100, 0), 1))
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name), \(model.percent)%")
    }
}
