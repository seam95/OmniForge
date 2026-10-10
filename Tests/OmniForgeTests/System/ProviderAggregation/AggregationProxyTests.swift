import XCTest
@testable import OmniForge

/// 代理主体：探活/404/发现端点、普通模型原样转发默认、命中改写上游名后转发、
/// 两种协议的 miss 信封、畸形体与缺 model 字段回落默认、上游非 2xx 原样透传。
final class AggregationProxyTests: XCTestCase {
    private var proxy: AggregationProxy!
    private var forwarder: StubForwarder!
    private var defaultTarget: AggregationProxyTarget!
    private var kimiTarget: AggregationProxyTarget!

    override func setUp() {
        defaultTarget = AggregationProxyTarget(
            key: "deepseek", profileID: "deepseek",
            baseURL: "https://api.deepseek.com/anthropic", token: "sk-ds"
        )
        kimiTarget = AggregationProxyTarget(
            key: "kimi", profileID: "kimi",
            baseURL: "https://api.kimi.com/coding", token: "sk-kimi"
        )
        let kimi = ProviderProfile(
            id: "kimi",
            name: "Kimi For Coding",
            tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding",
            token: "sk-kimi",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
        )
        forwarder = StubForwarder()
        proxy = AggregationProxy(
            resolver: AggregationTargetResolver(
                stack: .init(enabled: true, members: ["kimi"], keys: ["kimi": "kimi"]),
                registry: AggregationKeyRegistry(keys: ["kimi": "kimi"]),
                profiles: [kimi],
                defaultTarget: defaultTarget
            ),
            modelLister: StubModelLister(),
            forwarder: forwarder
        )
    }

    // MARK: - helpers

    private func makeRequest(method: String, path: String, body: Data) -> AggregationHTTPRequest {
        AggregationHTTPRequest(
            head: AggregationRequestHead(
                method: method,
                path: path,
                query: "",
                headers: ["content-type": "application/json"],
                contentLength: body.count
            ),
            body: body
        )
    }

    private func get(_ path: String, headers: [String: String] = [:]) -> AggregationHTTPRequest {
        makeRequest(method: "GET", path: path, body: Data())
    }

    private func post(_ path: String, body: String, headers: [String: String] = [:]) -> AggregationHTTPRequest {
        makeRequest(method: "POST", path: path, body: Data(body.utf8))
    }

    private func post(_ path: String, body: Data, headers: [String: String] = [:]) -> AggregationHTTPRequest {
        makeRequest(method: "POST", path: path, body: body)
    }

    // MARK: - stubs

    private final class StubForwarder: AggregationForwarding {
        var lastRequest: AggregationHTTPRequest?
        var lastTarget: AggregationProxyTarget?
        var lastProtocol: AggregationClientProtocol?
        var stubResponse: AggregationHTTPResponse?

        func forward(
            _ request: AggregationHTTPRequest,
            to target: AggregationProxyTarget,
            protocol: AggregationClientProtocol,
            completion: @escaping (Result<AggregationHTTPResponse, Error>) -> Void
        ) {
            lastRequest = request
            lastTarget = target
            lastProtocol = `protocol`
            completion(.success(stubResponse ?? AggregationHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            )))
        }
    }

    private final class StubModelLister: AggregationProxyModelListing {
        var models: [AggregationPublishedModel] = []
        func publishedModels() -> [AggregationPublishedModel] { models }
    }

    // MARK: - tests

    func test_health_returnsOK() {
        XCTAssertEqual(proxy.handle(get("/health")).statusCode, 200)
    }

    func test_unsupportedPath_returns404() {
        XCTAssertEqual(proxy.handle(post("/v1/embeddings", body: #"{"model":"x"}"#)).statusCode, 404)
    }

    func test_modelDiscovery_returnsAnthropicShapedList() throws {
        let response = proxy.handle(get("/v1/models", headers: ["anthropic-version": "2023-06-01"]))
        XCTAssertEqual(response.statusCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertNotNil(json["data"])
    }

    func test_plainModel_forwardsToDefaultWithBodyUnchanged() {
        let response = proxy.handle(post("/v1/messages", body: #"{"model":"claude-sonnet-4-6"}"#))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(forwarder.lastRequest?.body, Data(#"{"model":"claude-sonnet-4-6"}"#.utf8))
        XCTAssertEqual(forwarder.lastTarget, defaultTarget)
    }

    func test_prefixedModel_rewritesBodyModelToUpstreamNameBeforeForwarding() {
        _ = proxy.handle(post("/v1/messages", body: #"{"model":"ccs-claude-kimi--k3"}"#))
        XCTAssertEqual(forwarder.lastTarget, kimiTarget)
        let sent = try? JSONSerialization.jsonObject(with: forwarder.lastRequest!.body) as? [String: Any]
        XCTAssertEqual(sent?["model"] as? String, "k3")
    }

    func test_miss_returns400WithAnthropicEnvelope() throws {
        let response = proxy.handle(post("/v1/messages", body: #"{"model":"ccs-claude-nobody--x"}"#))
        XCTAssertEqual(response.statusCode, 400)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "error")
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertTrue((error["message"] as? String)?.contains("OmniForge") == true)
    }

    func test_miss_returns400WithOpenAIEnvelopeForCodex() throws {
        let response = proxy.handle(post("/v1/responses", body: #"{"model":"ccs-nobody/x"}"#))
        XCTAssertEqual(response.statusCode, 400)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "model_not_found")
        XCTAssertEqual(error["param"] as? String, "model")
        XCTAssertNil(json["type"])
    }

    func test_malformedBody_forwardsToDefaultInsteadOfFailing() {
        let response = proxy.handle(post("/v1/messages", body: Data("not json".utf8)))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(forwarder.lastTarget, defaultTarget)
        XCTAssertEqual(forwarder.lastRequest?.body, Data("not json".utf8))
    }

    func test_upstreamError_isPassedThroughVerbatim() {
        forwarder.stubResponse = AggregationHTTPResponse(statusCode: 429, headers: ["content-type": "application/json"],
                                                         body: Data(#"{"error":"rate limited"}"#.utf8))
        let response = proxy.handle(post("/v1/messages", body: #"{"model":"claude-sonnet-4-6"}"#))
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.body, Data(#"{"error":"rate limited"}"#.utf8))
    }

    func test_noModelField_forwardsToDefault() {
        _ = proxy.handle(post("/v1/messages", body: #"{"max_tokens":1}"#))
        XCTAssertEqual(forwarder.lastTarget, defaultTarget)
    }
}
