import Foundation

// MARK: - 提供商设置行状态装配（#10）

/// 提供商设置行的状态装配 — 纯函数，无状态；登录态/套餐/未配置引导均由限额快照派生。
enum TokenUsageProviderStatusBuilder {
    /// 行尾状态文本；nil = 尚未拉取该 provider 快照（行内只剩品牌名）。
    ///
    /// - 已配置（正常）：`Pro · ✓ 已登录`（planLabel 可缺省，纯符号 ✓ 无需本地化）；
    /// - 已配置但凭证过期：`需重新登录`（`LimitError.reauthRequired`）；
    /// - 未配置：`未登录 · 如何配置`（走 `tokenSettingsProviderStatusFormat` 装配）。
    static func statusText(limits: ProviderUsageLimits?, strings: Strings) -> String? {
        guard let limits else { return nil }
        guard limits.configured else {
            return String(
                format: strings.tokenSettingsProviderStatusFormat,
                strings.tokenSettingsNotConfigured,
                strings.tokenSettingsHowToConfigure
            )
        }
        if limits.issue == .reauthRequired {
            return strings.tokenStatusReauth
        }
        let signedIn = "✓ " + strings.tokenSettingsLoggedIn
        guard let planLabel = limits.planLabel, !planLabel.isEmpty else { return signedIn }
        return String(
            format: strings.tokenSettingsProviderStatusFormat,
            planLabel,
            signedIn
        )
    }

    /// 是否显示「如何配置 ›」引导（仅未配置；尚未拉取快照时不打扰）。
    static func showsConfigureGuide(_ limits: ProviderUsageLimits?) -> Bool {
        guard let limits else { return false }
        return !limits.configured
    }

    /// 「如何配置」展开后的说明文案（Cursor 无 CLI，走应用内登录文案）。
    static func configureHint(for provider: TokenUsageProvider, strings: Strings) -> String {
        if provider == .cursor {
            return strings.tokenSettingsConfigureHintCursor
        }
        return String(
            format: strings.tokenSettingsConfigureHintFormat,
            provider.setupCLICommand
        )
    }
}

// MARK: - Provider 设置引导

extension TokenUsageProvider {
    /// 「如何配置」引导涉及的 CLI 命令名（Cursor 无对应 CLI，返回 nil）。
    var setupCLICommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .kimi: return "kimi"
        case .cursor: return ""
        }
    }
}
