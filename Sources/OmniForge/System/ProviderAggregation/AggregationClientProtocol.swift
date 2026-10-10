import Foundation

/// 客户端请求的协议形状 — 决定模型 id 归属哪个工具、凭证头怎么重写、响应怎么封装。
enum AggregationClientProtocol: Equatable {
    /// Anthropic Messages 形状（Claude Code）。
    case anthropicMessages
    /// OpenAI Responses 形状（Codex）。
    case openAIResponses
    /// OpenAI Chat Completions 形状（Codex 兼容路径）。
    case openAIChatCompletions
    /// 模型发现（`/v1/models`）——内容协商见 `AggregationModelDiscovery`。
    case modelDiscovery
    /// 存活探活。
    case health
    /// 未命中路由表的方法/路径组合。
    case unsupported

    /// 该协议形状对应的工具（用于模型 id 解码）；本地应答的形状（发现/探活）无归属。
    var modelIDTool: ProviderTool? {
        switch self {
        case .anthropicMessages: return .claudeCode
        case .openAIResponses, .openAIChatCompletions: return .codex
        case .modelDiscovery, .health, .unsupported: return nil
        }
    }
}

/// 方法 + 路径 → 协议 的精确路由表。不做前缀通配——未命中即 `unsupported`（404）。
/// 路径覆盖三家客户端实际会打的端点（含 `/v1/v1/` 双前缀与 `/codex/` 前缀形态）。
enum AggregationRouteTable {
    static func protocolOf(method: String, path: String) -> AggregationClientProtocol {
        switch (method.uppercased(), path) {
        case ("POST", "/v1/messages"),
             ("POST", "/claude/v1/messages"),
             ("POST", "/v1/messages/count_tokens"):
            return .anthropicMessages
        case ("GET", "/v1/models"),
             ("GET", "/models"):
            return .modelDiscovery
        case ("POST", "/responses"),
             ("POST", "/v1/responses"),
             ("POST", "/v1/v1/responses"),
             ("POST", "/codex/v1/responses"),
             ("POST", "/v1/responses/compact"),
             ("POST", "/codex/v1/responses/compact"):
            return .openAIResponses
        case ("POST", "/chat/completions"),
             ("POST", "/v1/v1/chat/completions"):
            return .openAIChatCompletions
        case ("GET", "/health"),
             ("GET", "/status"):
            return .health
        default:
            return .unsupported
        }
    }
}
