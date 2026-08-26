import Foundation

/// 供应商预设（内置、只读、随 App 发布）— 一家供应商对一个或多个 CLI 工具的连接模板。
struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Claude Code 侧连接参数（该供应商未提供 Anthropic 兼容端点时为 nil）。
    let claudeCode: PresetConnection?
    /// Codex 侧连接参数（OpenAI 兼容端点；该供应商不提供时为 nil）。
    let codex: PresetConnection?
}

/// preset 内的单工具连接参数。
struct PresetConnection: Equatable {
    let baseURL: String
    /// 默认兜底模型（Claude 侧对应 `ANTHROPIC_MODEL`；Codex 侧即单模型）。
    let defaultModel: String
    /// Claude Code 侧角色模型映射（如无则 nil）。
    let modelMapping: ProviderModelMapping?
    /// 额外 env（如 `CLAUDE_CODE_EFFORT_LEVEL=max`）。
    let extraEnv: [String: String]
}

/// 内置供应商预设目录 — 首版 4 家：GLM / Kimi / DeepSeek / MiniMax。
/// 连接参数为随版本发布的数据（用户可在表单中修改后另存为自定义 profile）。
enum ProviderPresetCatalog {
    static let builtins: [ProviderPreset] = [glm, kimi, deepSeek, miniMax]

    static func preset(id: String) -> ProviderPreset? {
        builtins.first { $0.id == id }
    }

    /// GLM（智谱）— Anthropic 兼容端点 open.bigmodel.cn/api/anthropic；OpenAI 兼容 /api/v1。
    static let glm = ProviderPreset(
        id: "glm",
        displayName: "GLM 智谱",
        claudeCode: PresetConnection(
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            defaultModel: "glm-5.3",
            modelMapping: ProviderModelMapping(
                sonnet: "glm-5.3",
                sonnetName: nil,
                opus: "glm-5.3",
                opusName: nil,
                fable: "glm-5.3",
                fableName: nil,
                haiku: "glm-5.3-flash",
                haikuName: nil,
                subagent: "glm-5.3"
            ),
            extraEnv: [:]
        ),
        codex: PresetConnection(
            baseURL: "https://open.bigmodel.cn/api/v1",
            defaultModel: "glm-5.3",
            modelMapping: nil,
            extraEnv: [:]
        )
    )

    /// Kimi（月之暗面）— Claude Code 专用 Anthropic 兼容端点 api.kimi.com/coding；Codex 侧不提供 preset。
    static let kimi = ProviderPreset(
        id: "kimi",
        displayName: "Kimi 月之暗面",
        claudeCode: PresetConnection(
            baseURL: "https://api.kimi.com/coding",
            defaultModel: "k3[1m]",
            modelMapping: nil,
            extraEnv: [
                "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1048576",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1048576",
            ]
        ),
        codex: nil
    )

    /// DeepSeek — 官方支持 Claude Code（Anthropic 兼容端点 api.deepseek.com/anthropic）；OpenAI 兼容根路径。
    static let deepSeek = ProviderPreset(
        id: "deepseek",
        displayName: "DeepSeek",
        claudeCode: PresetConnection(
            baseURL: "https://api.deepseek.com/anthropic",
            defaultModel: "deepseek-v4-pro",
            modelMapping: ProviderModelMapping(
                sonnet: nil,
                sonnetName: nil,
                opus: nil,
                opusName: nil,
                fable: nil,
                fableName: nil,
                haiku: "deepseek-v4-flash",
                haikuName: nil,
                subagent: nil
            ),
            extraEnv: [
                "CLAUDE_CODE_EFFORT_LEVEL": "max",
                "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432",
            ]
        ),
        codex: PresetConnection(
            baseURL: "https://api.deepseek.com/",
            defaultModel: "deepseek-v4-pro",
            modelMapping: nil,
            extraEnv: [:]
        )
    )

    /// MiniMax — Anthropic 兼容端点 api.minimaxi.com/anthropic；OpenAI 兼容 api.minimax.io/v1。
    static let miniMax = ProviderPreset(
        id: "minimax",
        displayName: "MiniMax",
        claudeCode: PresetConnection(
            baseURL: "https://api.minimaxi.com/anthropic",
            defaultModel: "MiniMax-M3",
            modelMapping: nil,
            extraEnv: [:]
        ),
        codex: PresetConnection(
            baseURL: "https://api.minimax.io/v1",
            defaultModel: "MiniMax-M3",
            modelMapping: nil,
            extraEnv: [:]
        )
    )
}
