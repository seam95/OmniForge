import SwiftUI

/// Token 面板区头内联切换器（趋势周期 / Top 维度共用）：
/// 胶囊底 + 选中白底圆角块，font10Regular、选中 text1/未选中 text3，暗色分支同款。
/// 样式单一来源：改观感只动这里，各使用点不复制样式参数。
struct TokenUsageInlinePicker<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    var onChange: (Item) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                    onChange(item)
                } label: {
                    Text(label(item))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(
                            item == selection
                                ? (colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                                : (colorScheme == .light ? Theme.Stats.text3 : Color.secondary)
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            if item == selection {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Theme.Stats.cardBackground)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .light ? Theme.Stats.cardInset : Color.white.opacity(0.06))
        )
    }
}
