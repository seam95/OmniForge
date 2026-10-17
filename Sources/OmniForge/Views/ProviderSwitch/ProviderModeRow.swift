import SwiftUI

/// 模式双卡片选择器（直连 / 聚合）——替代原带折叠箭头的纯文本行。
///
/// 两种模式**互斥**：`~/.claude/settings.json` 与 Codex `config.toml` 同时只能容一个写入者，
/// 因此两张卡片以单选形式呈现。每张卡片展示自身模式下的实时状态摘要：
/// - 直连：未聚合时展示当前激活 profile（或官方账号），聚合生效时明确标示「已暂停」。
/// - 聚合：未开启时展示可加入家数，开启时展示成员数与默认供应商。
///
/// 默认展开哪一行不看用户上次选了什么，而看哪个模式**真的在生效**：聚合生效时若默认展开
/// 直连，用户第一眼看到的是一排被锁死的操作（见 `ProviderSwitchSettingsView.directActionsDisabled`）。
struct ProviderModeRow: View {
    let title: String
    let summary: String
    let isExpanded: Bool
    let accessibilityID: SettingsAccessibilityID
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    init(
        title: String,
        summary: String,
        isExpanded: Bool,
        accessibilityID: SettingsAccessibilityID,
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.summary = summary
        self.isExpanded = isExpanded
        self.accessibilityID = accessibilityID
        self.onToggle = onToggle
    }

    private var iconName: String {
        switch accessibilityID {
        case .providerModeDirectRow:
            return "arrow.triangle.swap"
        case .providerModeAggregationRow:
            return "square.stack.3d.up.fill"
        default:
            return "circle.grid.2x2"
        }
    }

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isExpanded ? Theme.accentColor : Color.secondary)

                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isExpanded ? (colorScheme == .dark ? .white : Theme.Stats.text1) : Color.secondary)

                    Spacer(minLength: 0)

                    if isExpanded {
                        Circle()
                            .fill(Theme.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }

                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isExpanded ? (colorScheme == .dark ? Color.white.opacity(0.85) : Theme.Stats.text2) : Color.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(strokeBorder, lineWidth: 1)
                    )
                    .shadow(
                        color: isExpanded ? ProviderCardVisual.selectedCardShadow(colorScheme) : (isHovered ? Color.black.opacity(0.04) : .clear),
                        radius: isExpanded ? 6 : 2,
                        x: 0,
                        y: isExpanded ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.hover) {
                isHovered = hovering
            }
        }
        .accessibilityIdentifier(accessibilityID.rawValue)
    }

    private var backgroundFill: Color {
        if colorScheme == .dark {
            if isExpanded {
                return Color.white.opacity(0.12)
            }
            return isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04)
        } else {
            if isExpanded {
                return ProviderCardVisual.selectedCardFill
            }
            return isHovered ? Color.white : Color(red: 0xF7 / 255.0, green: 0xF7 / 255.0, blue: 0xF9 / 255.0)
        }
    }

    private var strokeBorder: Color {
        if isExpanded {
            return ProviderCardVisual.activeBorder(colorScheme)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : ProviderCardVisual.border
    }

    // MARK: - 纯逻辑（可直测；界面测试按 AGENTS.md 缓行）

    /// 打开面板 / 切换工具时的默认展开行：哪个模式真的在生效就展开哪个。
    static func initialMode(isAggregating: Bool) -> ProviderAggregationManager.AggregationMode {
        isAggregating ? .aggregation : .direct
    }

    /// 直连行摘要。聚合生效时必须说明「已暂停」而非显示激活供应商——否则用户展开
    /// 才发现里面全是禁用控件。匹配不到 profile（未托管 / 损坏）时回落官方。
    static func directSummary(activeName: String?, isAggregating: Bool, strings: Strings) -> String {
        if isAggregating { return strings.providerModeDirectPaused }
        guard let activeName, !activeName.isEmpty else { return strings.providerModeDirectOfficial }
        return String(format: strings.providerModeDirectActiveFormat, activeName)
    }

    /// 聚合行摘要。未开启时标注可加入家数——有人可加入才值得点开；已开启时报家数与默认那家。
    static func aggregationSummary(
        members: [ProviderAggregationManager.AggregationMemberView],
        joinableCount: Int,
        strings: Strings
    ) -> String {
        guard let defaultMember = members.first(where: { $0.isDefault }) else {
            return joinableCount > 0
                ? String(format: strings.providerModeAggregationOffJoinableFormat, joinableCount)
                : strings.providerModeAggregationOff
        }
        return String(format: strings.providerModeAggregationOnFormat, members.count, defaultMember.name)
    }
}
