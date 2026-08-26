import Foundation

/// 目标 CLI 工具 — 供应商切换的作用对象（一个 Profile 只服务一个工具）。
enum ProviderTool: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    /// 配置文件文件名（settings.json / config.toml）。
    var configFileName: String {
        switch self {
        case .claudeCode: return "settings.json"
        case .codex: return "config.toml"
        }
    }

    /// profile 目录名（Claude 侧为 CCQ 兼容的 `providers/`；Codex 侧即 home 根目录）。
    var profileDirectoryName: String? {
        switch self {
        case .claudeCode: return "providers"
        case .codex: return nil
        }
    }
}

extension ProviderTool {
    /// Claude Code 拥有的 env 键 — 切 Official 时全部删除；写 profile 时只合并这些键。
    static let claudeOwnedEnvKeys: Set<String> = [
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
    ]

    /// Codex 顶层拥有的键（model_provider 指向激活的 provider 表）。
    static let codexOwnedTopLevelKeys: Set<String> = [
        "model_provider",
        "model",
    ]

    /// Codex `[model_providers.<key>]` 表内拥有的键 — 凭证直写 experimental_bearer_token，不走 env。
    static let codexOwnedProviderKeys: Set<String> = [
        "name",
        "base_url",
        "wire_api",
        "experimental_bearer_token",
    ]
}
