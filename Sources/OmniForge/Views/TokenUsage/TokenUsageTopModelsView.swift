import SwiftUI

/// Top 列表（模型 / App 双维度）：彩色圆点或品牌 logo（App 维度）+
/// 名称 + tokens 缩写 + 1 位小数占比% + 行底 12% 比例条（占比可视化）。
/// 区头右端挂「模型 | App」维度切换器（样式同趋势周期切换器）；空列表时整块不显示。
struct TokenUsageTopModelsView: View {
    let entries: [UsageTopModelEntry]
    @Binding var dimension: TokenUsageTopDimension
    let strings: Strings
    @Environment(\.colorScheme) private var colorScheme

    /// 名次圆点五色循环。
    private static let dotPalette: [Color] = [
        Color(.sRGB, red: 0.35, green: 0.55, blue: 0.95, opacity: 1.0),  // soft blue
        Color(.sRGB, red: 0.60, green: 0.45, blue: 0.90, opacity: 1.0),  // lavender
        Color(.sRGB, red: 0.30, green: 0.72, blue: 0.65, opacity: 1.0),  // teal
        Color(.sRGB, red: 0.90, green: 0.55, blue: 0.35, opacity: 1.0),  // warm amber
        Color(.sRGB, red: 0.70, green: 0.50, blue: 0.75, opacity: 1.0),  // muted plum
    ]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.Stats.cpu)
                .frame(width: 6, height: 6)
            Text(dimension.sectionTitle(strings))
                .font(.system(size: 12, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
            Spacer()
            TokenUsageInlinePicker(
                items: TokenUsageTopDimension.allCases,
                selection: $dimension,
                label: { $0.label(strings) }
            )
        }
    }

    private func row(_ entry: UsageTopModelEntry, index: Int) -> some View {
        HStack(spacing: 5) {
            leadingIcon(entry, index: index)
            Text(entry.name)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.name)
            Spacer(minLength: 4)
            Text(TokenUsageFormat.compactTokens(entry.tokens))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
            Text(TokenUsageFormat.percentOneDecimal(entry.percent))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        // 按占比铺底条，让占比可视化为比例而非只有数字列。
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.dotPalette[index % Self.dotPalette.count].opacity(0.12))
                    .frame(
                        width: geo.size.width * CGFloat(min(max(entry.percent / 100, 0), 1))
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.percent)%")
    }

    /// 行首列：App 维度用品牌 logo（16pt 规范组件缩至行高比例），模型维度保持名次彩色圆点。
    @ViewBuilder
    private func leadingIcon(_ entry: UsageTopModelEntry, index: Int) -> some View {
        if let provider = entry.provider {
            TokenUsageProviderIconView(provider: provider, size: 12, cornerRadius: 3)
        } else {
            Circle()
                .fill(Self.dotPalette[index % Self.dotPalette.count])
                .frame(width: 5, height: 5)
        }
    }
}
