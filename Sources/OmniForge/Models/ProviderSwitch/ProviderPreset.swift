import Foundation

/// 供应商预设（内置、只读、随 App 发布）— 一家供应商对一个或多个 CLI 工具的连接模板。
struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Claude Code 侧连接参数（该供应商未提供 Anthropic 兼容端点时为 nil）。
    let claudeCode: PresetConnection?
    /// Codex 侧连接参数（OpenAI 兼容端点；该供应商不提供时为 nil）。
    let codex: PresetConnection?
    /// Claude Desktop 侧连接参数（本期仅 Anthropic 兼容上游；无映射时为 nil）。
    let claudeDesktop: DesktopPresetConnection?
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

/// Claude Desktop 侧预设连接 — baseURL + 四档映射（键 = `ClaudeDesktopSettingsStore.defaultRoutes`）。
/// 六家内置预设全部配映射（现有默认模型无一 Claude-safe，直连会被 Desktop 白名单拒收）。
struct DesktopPresetConnection: Equatable {
    let baseURL: String
    let modelRoutes: [String: DesktopModelRoute]

    /// 便捷构造：主力档模型 + haiku 档模型（sonnet/opus/fable 共用主力档）。
    static func routes(main: String, haiku: String, oneM: Bool = false) -> [String: DesktopModelRoute] {
        [
            "claude-sonnet-5": DesktopModelRoute(model: main, labelOverride: nil, supports1M: oneM),
            "claude-opus-5": DesktopModelRoute(model: main, labelOverride: nil, supports1M: oneM),
            "claude-fable-5": DesktopModelRoute(model: main, labelOverride: nil, supports1M: oneM),
            "claude-haiku-4-5": DesktopModelRoute(model: haiku, labelOverride: nil, supports1M: false),
        ]
    }
}

/// 内置供应商预设目录 — 6 家：GLM / Kimi / DeepSeek / MiniMax / Step / OpenCode Go。
/// 连接参数为随版本发布的数据（用户可在表单中修改后另存为自定义 profile）。
enum ProviderPresetCatalog {
    static let builtins: [ProviderPreset] = [glm, kimi, deepSeek, miniMax, step, opencodeGo]

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
        ),
        claudeDesktop: DesktopPresetConnection(
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            modelRoutes: DesktopPresetConnection.routes(main: "glm-5.3", haiku: "glm-5.3-flash")
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
        codex: nil,
        claudeDesktop: DesktopPresetConnection(
            baseURL: "https://api.kimi.com/coding",
            modelRoutes: DesktopPresetConnection.routes(main: "k3", haiku: "k3", oneM: true)
        )
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
        ),
        claudeDesktop: DesktopPresetConnection(
            baseURL: "https://api.deepseek.com/anthropic",
            modelRoutes: DesktopPresetConnection.routes(main: "deepseek-v4-pro", haiku: "deepseek-v4-flash")
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
        ),
        claudeDesktop: DesktopPresetConnection(
            baseURL: "https://api.minimaxi.com/anthropic",
            modelRoutes: DesktopPresetConnection.routes(main: "MiniMax-M3", haiku: "MiniMax-M3")
        )
    )

    /// Step（阶跃星辰）— Step Plan 订阅；Anthropic 兼容端点 api.stepfun.com/step_plan（不带 /v1，SDK 自动拼 /v1/messages）；
    /// OpenAI 兼容端点 /step_plan/v1。主力档映射旗舰 step-5-preview，haiku 档映射代码向高速模型 step-3.5-flash。
    static let step = ProviderPreset(
        id: "step",
        displayName: "Step 阶跃星辰",
        claudeCode: PresetConnection(
            baseURL: "https://api.stepfun.com/step_plan",
            defaultModel: "step-5-preview",
            modelMapping: ProviderModelMapping(
                sonnet: "step-5-preview",
                sonnetName: nil,
                opus: "step-5-preview",
                opusName: nil,
                fable: "step-5-preview",
                fableName: nil,
                haiku: "step-3.5-flash",
                haikuName: nil,
                subagent: "step-5-preview"
            ),
            extraEnv: [:]
        ),
        codex: PresetConnection(
            baseURL: "https://api.stepfun.com/step_plan/v1",
            defaultModel: "step-5-preview",
            modelMapping: nil,
            extraEnv: [:]
        ),
        claudeDesktop: DesktopPresetConnection(
            baseURL: "https://api.stepfun.com/step_plan",
            modelRoutes: DesktopPresetConnection.routes(main: "step-5-preview", haiku: "step-3.5-flash")
        )
    )

    /// OpenCode Go — opencode.ai 订阅服务，按协议分组的多端点网关；
    /// Claude 侧走 Anthropic Messages 组（模型限该组：Qwen / MiniMax / Claude Haiku），Codex 侧走 Responses 组（Grok / GPT Luna）。
    /// 官方确认 Claude Code 原生 session header 可直连，无需额外 wrapper。
    static let opencodeGo = ProviderPreset(
        id: "opencodego",
        displayName: "OpenCode Go",
        claudeCode: PresetConnection(
            baseURL: "https://opencode.ai/inference/go/anthropic",
            defaultModel: "qwen3.8-max",
            modelMapping: ProviderModelMapping(
                sonnet: "qwen3.8-max",
                sonnetName: nil,
                opus: "qwen3.8-max",
                opusName: nil,
                fable: "qwen3.8-max",
                fableName: nil,
                haiku: "claude-haiku-5-5",
                haikuName: nil,
                subagent: "qwen3.8-max"
            ),
            extraEnv: [:]
        ),
        codex: PresetConnection(
            baseURL: "https://opencode.ai/inference/go/openai/v1",
            defaultModel: "grok-4.7",
            modelMapping: nil,
            extraEnv: [:]
        ),
        claudeDesktop: DesktopPresetConnection(
            baseURL: "https://opencode.ai/inference/go/anthropic",
            modelRoutes: DesktopPresetConnection.routes(main: "qwen3.8-max", haiku: "claude-haiku-5-5")
        )
    )
}
