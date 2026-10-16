import SwiftUI

/// 模式两行（直连 / 聚合）——替代原「直连 / 聚合」分段行。
///
/// 两种模式**互斥**：`~/.claude/settings.json` 与 Codex `config.toml` 同时只能容一个写入者，
/// 所以一行展开时另一行必折叠。折叠行带状态摘要，这是两行相对分段行多出来的信息量——
/// 分段行只有标题，用户停在直连时根本看不出聚合开了没有、有几家。
///
/// 默认展开哪一行不看用户上次选了什么，而看哪个模式**真的在生效**：聚合生效时若默认展开
/// 直连，用户第一眼看到的是一排被锁死的操作（见 `ProviderSwitchSettingsView.directActionsDisabled`）。
struct ProviderModeRow: View {
    let title: String
    let summary: String
    let isExpanded: Bool
    let accessibilityID: SettingsAccessibilityID
    let onToggle: () -> Void

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

    var body: some View {
        // macOS 上 DisclosureGroup 的自定义文本 label 不响应点击（仅左侧箭头可点），
        // 因此自绘折叠行并显式接管点击，保证整行可切换（同 ProfileEditorView 的显示名折叠行）。
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(summary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isExpanded ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID.rawValue)
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
