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

    func test_rewrittenHeaders_usesBearerForOpenAIProtocols() {
        let headers = ["authorization": "Bearer PROXY_MANAGED"]
        let rewritten = AggregationUpstream.rewrittenHeaders(headers, credential: "sk-real", protocol: .openAIResponses)
        XCTAssertEqual(rewritten["authorization"], "Bearer sk-real")
    }
}
