import SwiftUI

/// 层级详情页统一返回栏：返回按钮（箭头 + 标题整体热区，悬停浅色圆角底）
/// + 右侧动作位（如刷新）+ 底部发丝线。
/// 统一监控排行/风扇/磁盘详情与实用工具详情的返回形态：
/// 热区取「箭头 + 标题」整体，视觉取 hover 反馈与发丝线容器。
struct FlatBackBar<Trailing: View>: View {
    let title: String
    let backLabel: String
    let onBack: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        backLabel: String,
        onBack: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.backLabel = backLabel
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(Theme.Animation.hover) {
                    isHovered = hovering
                }
            }
            .accessibilityLabel(backLabel)

            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            FlatHairline()
        }
    }
}
