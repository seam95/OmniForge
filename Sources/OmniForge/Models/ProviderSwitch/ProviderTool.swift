import Foundation

/// 目标 CLI 工具 — 供应商切换的作用对象（一个 Profile 只服务一个工具）。
enum ProviderTool: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case claudeDesktop

    var id: String { rawValue }

    /// 配置文件文件名（settings.json / config.toml / claude_desktop_config.json）。
    /// Desktop 侧仅展示用：实际写入目标是 4 文件事务（SPEC 关键设计决策 2）。
    var configFileName: String {
        switch self {
        case .claudeCode: return "settings.json"
        case .codex: return "config.toml"
        case .claudeDesktop: return "claude_desktop_config.json"
        }
    }

    /// profile 目录名（Claude 侧为 CCQ 兼容的 `providers/`；Codex 侧即 home 根目录）。
    /// Desktop 档案在 App Support（`ProviderSwitchPaths.profileDirectory`），
    /// 不属于 home 相对布局，故不参与此映射 — 返回 nil 仅为穷尽性，不可消费。
    var profileDirectoryName: String? {
        switch self {
        case .claudeCode: return "providers"
        case .codex: return nil
        case .claudeDesktop: return nil
        }
    }
}

extension ProviderTool {
    /// Claude Code 基础拥有 env 键 — 切 Official 时全部删除；写 profile 时只合并这些键。
    /// 含旧版 `ANTHROPIC_SMALL_FAST_MODEL`（已由 Haiku 映射取代，仍一并清理）与
    /// ccswitch 风格的角色映射键（`ANTHROPIC_DEFAULT_*`、`CLAUDE_CODE_SUBAGENT_MODEL`）。
    /// 这些键都有 profile 专属字段（token/baseURL/modelOverride/modelMapping），
    /// 导入外部文件时被专属字段消费，不进入 `extraEnv`。
    static let claudeCoreEnvKeys: Set<String> = [
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    ]

    /// 聚合模式计算写入的窗口/兼容键（对齐 cc-switch `CLAUDE_EXCLUSIVE_ENV`）。
    /// 没有专属 profile 字段：直连模式下经 `extraEnv` 原样合并，
    /// 导入外部文件时必须保留在 `extraEnv`（否则预设的窗口键会在 upsert→list 往返中丢失）。
    static let claudeAggregationEnvKeys: Set<String> = [
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
        "CLAUDE_CODE_DISABLE_1M_CONTEXT",
        "CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT",
        "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
        "CLAUDE_CODE_DISABLE_ARTIFACT",
        "CLAUDE_CODE_DISABLE_THINKING",
        "DISABLE_INTERLEAVED_THINKING",
        "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT",
        "CLAUDE_CODE_EXTRA_BODY",
        "CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING",
        "CLAUDE_CODE_AUTO_MODE_SERVER",
        "ENABLE_TOOL_SEARCH",
    ]

    /// Claude Code 拥有的全部 env 键 = 基础键 ∪ 聚合窗口键。
    /// clearOverrides 与聚合投影以此为准；导入过滤用 `claudeCoreEnvKeys`。
    static let claudeOwnedEnvKeys: Set<String> = claudeCoreEnvKeys.union(claudeAggregationEnvKeys)

    /// Claude Code `settings.json` 顶层拥有的键 — 聚合模式的 `modelPicker` 落在此层
    /// （不是 `env` 内），退出聚合时整键删除。
    static let claudeOwnedTopLevelKeys: Set<String> = ["modelPicker"]

    /// Codex 顶层拥有的键（model_provider 指向激活的 provider 表）。
    /// 后半段窗口/兼容键是聚合模式要计算写入的；直连模式下经 `extraEnv` 原样合并。
    static let codexOwnedTopLevelKeys: Set<String> = [
        "model_provider",
        "model",
        "model_reasoning_effort",
        "model_catalog_json",
        // MARK: 聚合模式窗口键（计算写入；直连模式经 extraEnv 原样合并）
        "model_context_window",
        "model_auto_compact_token_limit",
        "openai_base_url",
        "review_model",
        "plan_mode_reasoning_effort",
        "disable_response_storage",
    ]

    /// Codex `[model_providers.<key>]` 表内拥有的键 — 凭证直写 experimental_bearer_token，不走 env。
    static let codexOwnedProviderKeys: Set<String> = [
        "name",
        "base_url",
        "wire_api",
        "requires_openai_auth",
        "experimental_bearer_token",
    ]

    /// Codex 自带的内置 provider 键（`codex login` 默认配置）— 指向它们视为 Official，
    /// 切 Official 时不得删除对应表（那是 CLI 自身的登录配置）。
    static let codexBuiltInProviderKeys: Set<String> = ["openai", "codex"]
}
