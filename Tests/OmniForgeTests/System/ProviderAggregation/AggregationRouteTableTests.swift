import XCTest
@testable import OmniForge

/// 代理协议判定（精确路径表）与上游请求构造（base 归一化、URL 拼接、凭证头重写）。
final class AggregationRouteTableTests: XCTestCase {
    func test_protocolOf_mapsEverySupportedPath() {
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/messages"), .anthropicMessages)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/claude/v1/messages"), .anthropicMessages)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/messages/count_tokens"), .anthropicMessages)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "GET", path: "/v1/models"), .modelDiscovery)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "GET", path: "/models"), .modelDiscovery)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/responses"), .openAIResponses)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/responses"), .openAIResponses)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/v1/responses"), .openAIResponses)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/codex/v1/responses"), .openAIResponses)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/responses/compact"), .openAIResponses)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/codex/v1/responses/compact"), .openAIResponses)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/chat/completions"), .openAIChatCompletions)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/v1/chat/completions"), .openAIChatCompletions)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "GET", path: "/health"), .health)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "GET", path: "/status"), .health)
    }

    func test_protocolOf_getResponsesIsWebsocketProbe() {
        for path in ["/responses", "/v1/responses", "/v1/v1/responses", "/codex/v1/responses"] {
            XCTAssertEqual(AggregationRouteTable.protocolOf(method: "GET", path: path), .websocketProbe, path)
        }
    }

    func test_protocolOf_alphaAndImagesEndpointsArePassthrough() {
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/alpha/search"), .codexPassthrough)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/alpha/search"), .codexPassthrough)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/codex/v1/alpha/search"), .codexPassthrough)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/images/generations"), .codexPassthrough)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/v1/images/edits"), .codexPassthrough)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/codex/v1/images/generations"), .codexPassthrough)
    }

    func test_protocolOf_unknownPathOrMethodIsUnsupported() {
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "GET", path: "/v1/messages"), .unsupported)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "POST", path: "/v1/embeddings"), .unsupported)
        XCTAssertEqual(AggregationRouteTable.protocolOf(method: "PUT", path: "/v1/messages"), .unsupported)
    }

    func test_modelIDTool_followsProtocol() {
        XCTAssertEqual(AggregationClientProtocol.anthropicMessages.modelIDTool, .claudeCode)
        XCTAssertEqual(AggregationClientProtocol.openAIResponses.modelIDTool, .codex)
        XCTAssertEqual(AggregationClientProtocol.openAIChatCompletions.modelIDTool, .codex)
        XCTAssertNil(AggregationClientProtocol.modelDiscovery.modelIDTool)
        XCTAssertNil(AggregationClientProtocol.health.modelIDTool)
    }

    func test_normalizedBase_stripsSingleTrailingV1() {
        XCTAssertEqual(AggregationUpstream.normalizedBase("https://open.bigmodel.cn/api/v1"), "https://open.bigmodel.cn/api")
        XCTAssertEqual(AggregationUpstream.normalizedBase("https://open.bigmodel.cn/api/v1/"), "https://open.bigmodel.cn/api")
        XCTAssertEqual(AggregationUpstream.normalizedBase("https://api.deepseek.com/"), "https://api.deepseek.com")
        XCTAssertEqual(AggregationUpstream.normalizedBase("https://api.kimi.com/coding"), "https://api.kimi.com/coding")
    }

    func test_upstreamURL_joinsNormalizedBaseWithClientPath() {
        XCTAssertEqual(AggregationUpstream.upstreamURL(base: "https://open.bigmodel.cn/api/v1", clientPath: "/v1/responses")?.absoluteString,
                       "https://open.bigmodel.cn/api/v1/responses")
        XCTAssertEqual(AggregationUpstream.upstreamURL(base: "https://api.deepseek.com/", clientPath: "/v1/responses")?.absoluteString,
                       "https://api.deepseek.com/v1/responses")
        XCTAssertEqual(AggregationUpstream.upstreamURL(base: "https://api.kimi.com/coding", clientPath: "/v1/messages")?.absoluteString,
                       "https://api.kimi.com/coding/v1/messages")
    }

    /// ChatGPT Codex 后端的端点是 `/responses`（无版本段）：客户端按本地代理 base
    /// （`http://127.0.0.1:PORT/v1`）发来 `/v1/responses`，拼到该后端必须剥掉 `/v1`，
    /// 否则 404/401。其余上游的分支行为不受影响（版本段由 base 吸收）。
    func test_upstreamURL_stripsV1ForChatGPTBackend() {
        XCTAssertEqual(AggregationUpstream.upstreamURL(base: "https://chatgpt.com/backend-api/codex", clientPath: "/v1/responses")?.absoluteString,
                       "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(AggregationUpstream.upstreamURL(base: "https://chatgpt.com/backend-api/codex/", clientPath: "/v1/responses/compact")?.absoluteString,
                       "https://chatgpt.com/backend-api/codex/responses/compact")
        XCTAssertEqual(AggregationUpstream.upstreamURL(base: "https://chatgpt.com/backend-api/codex", clientPath: "/responses")?.absoluteString,
                       "https://chatgpt.com/backend-api/codex/responses", "客户端没带 /v1 时原样拼接")
    }

    /// ChatGPT 订阅的 OAuth token 只在 chatgpt.com 后端有效：官方透传目标的 base
    /// 必须规整成该后端（api.openai.com 只认 API key，OAuth token 打到那里就是 401）。
    func test_officialOAuthBaseURL_isChatGPTBackend() {
        XCTAssertEqual(AggregationUpstream.officialOAuthBaseURL, "https://chatgpt.com/backend-api/codex")
    }

    func test_rewrittenHeaders_replacesPlaceholderWithRealCredential() {
        let headers = ["x-api-key": "PROXY_MANAGED", "anthropic-version": "2023-06-01", "content-type": "application/json",
                       "host": "127.0.0.1:15721", "content-length": "12", "accept-encoding": "gzip, br"]
        let rewritten = AggregationUpstream.rewrittenHeaders(headers, credential: "sk-real", protocol: .anthropicMessages)
        XCTAssertEqual(rewritten["x-api-key"], "sk-real")
        XCTAssertEqual(rewritten["anthropic-version"], "2023-06-01")
        XCTAssertNil(rewritten["host"])
        XCTAssertNil(rewritten["content-length"])
        XCTAssertNil(rewritten["accept-encoding"])
    }

    func test_rewrittenHeaders_anthropicMergesClaudeCodeBetaAndBackfillsVersion() {
        // anthropic-beta：客户端已有其他 beta → 合并去重并确保含 claude-code-20250219（cc-switch forwarder.rs:2364-2392）
        let merged = AggregationUpstream.rewrittenHeaders(
            ["anthropic-beta": "context-1m-2025-08-07", "content-type": "application/json"],
            credential: "sk-real", protocol: .anthropicMessages)
        let betas = Set((merged["anthropic-beta"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(betas.contains("claude-code-20250219"))
        XCTAssertTrue(betas.contains("context-1m-2025-08-07"))

        // anthropic-version：缺失补 2023-06-01（cc-switch forwarder.rs:2629-2635）
        XCTAssertEqual(merged["anthropic-version"], "2023-06-01")

        // 客户端已有 version → 原样保留
        let kept = AggregationUpstream.rewrittenHeaders(["anthropic-version": "2024-01-01"],
            credential: "sk", protocol: .anthropicMessages)
        XCTAssertEqual(kept["anthropic-version"], "2024-01-01")

        // 无 beta 头 → 仅写 claude-code-20250219
        let fresh = AggregationUpstream.rewrittenHeaders([:], credential: "sk", protocol: .anthropicMessages)
        XCTAssertEqual(fresh["anthropic-beta"], "claude-code-20250219")
    }

    func test_rewrittenHeaders_anthropicKeepsBetaUnchangedWhenClaudeCodeAlreadyPresent() {
        // 已含 claude-code-20250219 → 原样保留：证明是无条件前置之外的真实判定，重复前置会在此暴露
        let exact = AggregationUpstream.rewrittenHeaders(
            ["anthropic-beta": "claude-code-20250219,context-1m-2025-08-07"],
            credential: "sk-real", protocol: .anthropicMessages)
        XCTAssertEqual(exact["anthropic-beta"], "claude-code-20250219,context-1m-2025-08-07")

        // 逗号两侧带空白也能识别为已含（split 后逐项 trim），值同样原样保留
        let padded = AggregationUpstream.rewrittenHeaders(
            ["anthropic-beta": " claude-code-20250219 , context-1m-2025-08-07 "],
            credential: "sk-real", protocol: .anthropicMessages)
        XCTAssertEqual(padded["anthropic-beta"], " claude-code-20250219 , context-1m-2025-08-07 ")

        // 已含 beta 时 version 仍走各自的规则：缺失补默认值，已有值不覆盖
        XCTAssertEqual(exact["anthropic-version"], "2023-06-01")
        let withVersion = AggregationUpstream.rewrittenHeaders(
            ["anthropic-beta": "claude-code-20250219", "anthropic-version": "2024-01-01"],
            credential: "sk-real", protocol: .anthropicMessages)
        XCTAssertEqual(withVersion["anthropic-version"], "2024-01-01")
    }

    func test_rewrittenHeaders_usesBearerForOpenAIProtocols() {
        let headers = ["authorization": "Bearer PROXY_MANAGED"]
        let rewritten = AggregationUpstream.rewrittenHeaders(headers, credential: "sk-real", protocol: .openAIResponses)
        XCTAssertEqual(rewritten["authorization"], "Bearer sk-real")
    }

    func test_rewrittenHeaders_officialRoutePassesClientAuthorizationThrough() {
        let headers = ["authorization": "Bearer codex-oauth-token", "content-type": "application/json"]
        let rewritten = AggregationUpstream.rewrittenHeaders(headers, credential: "PROXY_MANAGED",
                                                             protocol: .openAIResponses, passthroughAuthorization: true)
        XCTAssertEqual(rewritten["authorization"], "Bearer codex-oauth-token", "官方路由的 Authorization 原样透传")
    }

    /// 透传只压掉「凭证替换」这一步：逐跳头照剔、Claude 客户端头照补，
    /// 客户端的 `authorization` 与 `x-api-key` 一律不被占位凭证覆盖（cc-switch `forwarder.rs:2462-2467`）。
    func test_rewrittenHeaders_passthroughSuppressesCredentialSubstitutionOnly() {
        let headers = ["authorization": "Bearer codex-oauth-token", "x-api-key": "client-own-key",
                       "content-type": "application/json",
                       "host": "127.0.0.1:15721", "content-length": "12", "accept-encoding": "gzip, br"]
        let rewritten = AggregationUpstream.rewrittenHeaders(headers, credential: "PROXY_MANAGED",
                                                             protocol: .anthropicMessages, passthroughAuthorization: true)
        XCTAssertEqual(rewritten["authorization"], "Bearer codex-oauth-token", "凭证头原样：Scheme 与本体都不动")
        XCTAssertEqual(rewritten["x-api-key"], "client-own-key", "凭证头原样：x-api-key 同样不替换")
        XCTAssertNil(rewritten["host"])
        XCTAssertNil(rewritten["content-length"])
        XCTAssertNil(rewritten["accept-encoding"], "逐跳头与透传无关，两种模式都剔")
        XCTAssertEqual(rewritten["anthropic-version"], "2023-06-01", "Claude 客户端头与凭证无关，照旧补")
    }
}
