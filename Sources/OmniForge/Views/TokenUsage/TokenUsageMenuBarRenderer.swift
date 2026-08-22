import Foundation

// MARK: - 菜单栏「今日 tokens」贡献（#06）

/// token 菜单栏渲染输出（纯值状态，可等值比较）。
struct TokenUsageMenuBarRender: Equatable {
    /// nil = 不显示；无数据 / 关闭模式 / 未安装时整体隐藏，不渲染 0k 占位。
    var block: MenuBarMetricRenderer.MetricBlock?

    var isVisible: Bool { block != nil }
}

/// 输入（安装态 + 用量快照 + 限额快照 + 菜单栏模式 + label）→ 菜单栏块的纯函数映射。
enum TokenUsageMenuBarRenderer {
    /// 今日 tokens 块的最宽占位：整数 k/m 口径最长 4 字符（"999k"），预留宽度防抖动。
    static let todayMinimumValue = "999k"
    /// 会话窗 % 块的最宽占位："100%" 最长 4 字符，预留宽度防抖动。
    static let sessionMinimumValue = "100%"

    static func render(
        isFeatureAvailable: Bool,
        overview: TokenUsageOverview?,
        mode: TokenUsageMenuBarMode,
        label: String,
        limits: [TokenUsageProvider: ProviderUsageLimits] = [:]
    ) -> TokenUsageMenuBarRender {
        guard isFeatureAvailable else { return TokenUsageMenuBarRender(block: nil) }
        switch mode {
        case .todayTokens:
            guard let overview else { return TokenUsageMenuBarRender(block: nil) }
            return TokenUsageMenuBarRender(block: MenuBarMetricRenderer.MetricBlock(
                label: label,
                value: TokenUsageFormat.menubarTokens(overview.totalTokens),
                minimumValue: Self.todayMinimumValue
            ))
        case .sessionPercent:
            // #10：消费限额数据；口径不成立（多家已配置 / 无会话窗）时整体隐藏。
            guard let percent = sessionWindowPercent(limits: limits) else {
                return TokenUsageMenuBarRender(block: nil)
            }
            return TokenUsageMenuBarRender(block: MenuBarMetricRenderer.MetricBlock(
                label: label,
                value: TokenUsageFormat.percent(percent),
                minimumValue: Self.sessionMinimumValue
            ))
        case .hidden:
            return TokenUsageMenuBarRender(block: nil)
        }
    }

    // MARK: - 会话窗用量 %

    /// 会话窗用量 %（SPEC 4.4「当前会话窗用量%」）：每家会话窗重置节奏各异，
    /// 恰有一家已配置且带会话窗时才给出确定口径，否则 nil（多口径无法聚合，整体隐藏）。
    static func sessionWindowPercent(limits: [TokenUsageProvider: ProviderUsageLimits]) -> Double? {
        let configured = limits.filter { $0.value.configured }
        guard configured.count == 1, let entry = configured.first else { return nil }
        guard let percent = entry.value.windows[.session]?.usedPercent, percent.isFinite else {
            return nil
        }
        return percent
    }
}
