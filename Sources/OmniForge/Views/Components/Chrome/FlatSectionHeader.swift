import SwiftUI

/// 平面分区公共元素：发丝线、区头、tint 提示横幅。
/// 规范来源：监控/Token 平面分区语言（docs/active/2026-09-05-实用工具页平面分区重构/SPEC.md §4）。
/// 监控/Token 页自身未迁移到本组件（历史代码逐字复刻同一样式，避免范围蔓延时不动）。

/// 相邻分区之间的 1pt 发丝线（浅 #F0F0F0 / 深 primary 10%）。
/// 只作节奏切分；列表行内分隔请用 `Theme.Stats.separator`。
struct FlatHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(MonitorOverviewPalette.hairline(colorScheme))
            .frame(height: 1)
    }
}

/// 平面分区标题行：6×6 圆角 2 色块 + 12 semibold tracking(1) 次色标题 + 右侧附属区。
struct FlatSectionHeader<Trailing: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        accent: Color,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.accent = accent
        self.trailing = trailing
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 6, height: 6)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing()
        }
    }
}

/// tint 提示横幅：提示色低透明底（浅 0.06 / 深 0.12），可选同色系描边。
/// 工具页默认无描边圆角 8；供应商卡片场景传 `bordered: true` 保持原视觉。
struct PanelTintBanner<Action: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String?
    let cornerRadius: CGFloat
    let bordered: Bool
    @ViewBuilder let action: () -> Action

    init(
        icon: String,
        tint: Color,
        title: String,
        message: String? = nil,
        cornerRadius: CGFloat = Theme.Radius.row,
        bordered: Bool = false,
        @ViewBuilder action: @escaping () -> Action = { EmptyView() }
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.cornerRadius = cornerRadius
        self.bordered = bordered
        self.action = action
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    .lineLimit(1)
            }

            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer(minLength: 0)
                action()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.06))
        )
        .overlay(
            Group {
                if bordered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 1)
                }
            }
        )
    }
}
