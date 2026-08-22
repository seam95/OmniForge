import Foundation

// MARK: - 菜单栏「今日 tokens」贡献（#06）

/// token 菜单栏渲染输出（纯值状态，可等值比较）。
struct TokenUsageMenuBarRender: Equatable {
    /// nil = 不显示；无数据 / 关闭模式 / 未安装时整体隐藏，不渲染 0k 占位。
    var block: MenuBarMetricRenderer.MetricBlock?

    var isVisible: Bool { block != nil }
}

/// 输入（安装态 + 用量快照 + 菜单栏模式 + label）→ 菜单栏块的纯函数映射。
enum TokenUsageMenuBarRenderer {
    /// 今日 tokens 块的最宽占位：整数 k/m 口径最长 4 字符（"999k"），预留宽度防抖动。
    static let todayMinimumValue = "999k"

    static func render(
        isFeatureAvailable: Bool,
        overview: TokenUsageOverview?,
        mode: TokenUsageMenuBarMode,
        label: String
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
            // #10 预留：会话窗用量 % 依赖限额数据，本票不产出块（渲染结构已留开关分支）。
            return TokenUsageMenuBarRender(block: nil)
        case .hidden:
            return TokenUsageMenuBarRender(block: nil)
        }
    }
}
