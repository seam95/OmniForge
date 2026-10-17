import SwiftUI

/// 聚合模式置顶功能开关卡片（替代原第三层直连/聚合 Tab）：
/// - 展示聚合功能图标、标题与实时运行摘要
/// - 右端提供原生风格 Toggle 开关，开关操作触发进入/退出聚合确认流程
/// - 开启时展示运行中绿色指示点与成员/模型数，关闭时展示可加入数量
struct AggregationToggleCard: View {
    let tool: ProviderTool
    let isAggregating: Bool
    let summary: String
    let strings: Strings
    let onToggleRequest: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isAggregating ? Theme.accentColor.opacity(0.12) : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)))
                    .frame(width: 32, height: 32)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isAggregating ? Theme.accentColor : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(strings.providerModeAggregation)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ProviderCardVisual.primaryText(colorScheme))

                    if isAggregating {
                        Text(strings.providerInUseBadge)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(ProviderCardVisual.badgeText(colorScheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(ProviderCardVisual.badgeBackground(colorScheme)))
                    }
                }

                if isAggregating {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text(summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(ProviderCardVisual.secondaryText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { isAggregating },
                set: { wantOn in onToggleRequest(wantOn) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(cardStroke, lineWidth: 1)
                )
                .shadow(
                    color: isAggregating ? ProviderCardVisual.selectedCardShadow(colorScheme) : (isHovered ? Color.black.opacity(0.03) : .clear),
                    radius: isAggregating ? 6 : 2,
                    x: 0,
                    y: isAggregating ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .accessibilityIdentifier(SettingsAccessibilityID.providerModeAggregationRow.rawValue)
    }

    private var cardFill: Color {
        if colorScheme == .dark {
            return isAggregating ? Color.white.opacity(0.10) : Color.white.opacity(0.04)
        } else {
            return isAggregating ? ProviderCardVisual.selectedCardFill : Color.white
        }
    }

    private var cardStroke: Color {
        if isAggregating {
            return ProviderCardVisual.activeBorder(colorScheme)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : ProviderCardVisual.border
    }
}
