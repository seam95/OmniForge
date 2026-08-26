import Foundation

/// 供应商预设（内置、只读、随 App 发布）— 一家供应商对一个或多个 CLI 工具的连接模板。
struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Claude Code 侧连接参数（该供应商未提供 Anthropic 兼容端点时为 nil）。
    let claudeCode: PresetConnection?
    /// Codex 侧连接参数（OpenAI 兼容端点）。
    let codex: PresetConnection?
}

/// preset 内的单工具连接参数。
struct PresetConnection: Equatable {
    let baseURL: String
    let defaultModel: String
    /// Claude Code 侧小模型（如无则 nil）。
    let defaultSmallFastModel: String?
}

/// 内置供应商预设目录 — 首版 4 家：GLM / Kimi / DeepSeek / MiniMax。
/// 连接参数为随版本发布的数据（用户可在表单中修改后另存为自定义 profile）。
enum ProviderPresetCatalog {
    static let builtins: [ProviderPreset] = [glm, kimi, deepSeek, miniMax]

    static func preset(id: String) -> ProviderPreset? {
        builtins.first { $0.id == id }
    }

    /// GLM（智谱）— Anthropic 兼容端点 open.bigmodel.cn/api/anthropic；OpenAI 兼容 paas/v4。
    static let glm = ProviderPreset(
        id: "glm",
        displayName: "GLM",
        claudeCode: PresetConnection(
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            defaultModel: "glm-4-7",
            defaultSmallFastModel: nil
        ),
        codex: PresetConnection(
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-7",
            defaultSmallFastModel: nil
        )
    )

    /// Kimi（月之暗面）— Anthropic 兼容端点 api.moonshot.cn/anthropic；OpenAI 兼容 /v1。
    static let kimi = ProviderPreset(
        id: "kimi",
        displayName: "Kimi",
        claudeCode: PresetConnection(
            baseURL: "https://api.moonshot.cn/anthropic",
            defaultModel: "kimi-k2-thinking-turbo",
            defaultSmallFastModel: nil
        ),
        codex: PresetConnection(
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2-thinking-turbo",
            defaultSmallFastModel: nil
        )
    )

    /// DeepSeek — 官方支持 Claude Code（Anthropic 兼容端点 api.deepseek.com/anthropic）；OpenAI 兼容 /v1。
    static let deepSeek = ProviderPreset(
        id: "deepseek",
        displayName: "DeepSeek",
        claudeCode: PresetConnection(
            baseURL: "https://api.deepseek.com/anthropic",
            defaultModel: "deepseek-chat",
            defaultSmallFastModel: nil
        ),
        codex: PresetConnection(
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            defaultSmallFastModel: nil
        )
    )

    /// MiniMax — Anthropic 兼容端点 api.minimaxi.com/anthropic；OpenAI 兼容 /v1。
    static let miniMax = ProviderPreset(
        id: "minimax",
        displayName: "MiniMax",
        claudeCode: PresetConnection(
            baseURL: "https://api.minimaxi.com/anthropic",
            defaultModel: "minimax-m2",
            defaultSmallFastModel: nil
        ),
        codex: PresetConnection(
            baseURL: "https://api.minimaxi.com/v1",
            defaultModel: "minimax-m2",
            defaultSmallFastModel: nil
        )
    )
}
