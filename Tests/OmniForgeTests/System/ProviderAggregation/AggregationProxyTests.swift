import XCTest
@testable import OmniForge

/// 代理主体：探活/404/发现端点、普通模型原样转发默认、命中改写上游名后转发、
/// 两种协议的 miss 信封、畸形体与缺 model 字段回落默认、上游非 2xx 原样透传。
final class AggregationProxyTests: XCTestCase {
    private var proxy: AggregationProxy!
    private var forwarder: StubForwarder!
    private var sealStore: AggregationRefusedSealStore!
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
        sealStore = AggregationRefusedSealStore()
        sealStore.reset()
        proxy = AggregationProxy(
            resolver: AggregationTargetResolver(
                stack: .init(enabled: true, members: ["kimi"], keys: ["kimi": "kimi"]),
                registry: AggregationKeyRegistry(keys: ["kimi": "kimi"]),
                profiles: [kimi],
                defaultTarget: defaultTarget
            ),
            modelLister: StubModelLister(),
            forwarder: forwarder,
            sealStore: sealStore
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

        /// 数据面不经本 stub（单测只走 `handle` 的完成式聚合）；记录后立即完成。
        func stream(
            request: AggregationHTTPRequest,
            to target: AggregationProxyTarget,
            protocol: AggregationClientProtocol,
            onHead: @escaping (Int, [String: String]) -> Void,
            onChunk: @escaping (Data) -> Void,
            onComplete: @escaping (Error?) -> Void
        ) {
            lastRequest = request
            lastTarget = target
            lastProtocol = `protocol`
            let response = stubResponse ?? AggregationHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            )
            onHead(response.statusCode, response.headers)
            onChunk(response.body)
            onComplete(nil)
        }
    }

    private final class StubModelLister: AggregationProxyModelListing {
        var models: [AggregationPublishedModel] = []
        func publishedModels(tool: ProviderTool) -> [AggregationPublishedModel] { models }
    }

    // MARK: - tests

    func test_health_returnsOK() {
        XCTAssertEqual(proxy.handle(get("/health")).statusCode, 200)
    }

    func test_unsupportedPath_returns404() {
        XCTAssertEqual(proxy.handle(post("/v1/embeddings", body: #"{"model":"x"}"#)).statusCode, 404)
    }

    func test_websocketProbe_returns426WithNotSupportedEnvelope() throws {
        let response = proxy.handle(get("/v1/responses"))
        XCTAssertEqual(response.statusCode, 426)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertEqual(error["code"] as? String, "websocket_not_supported")
        XCTAssertTrue((error["message"] as? String)?.contains("OmniForge") == true)
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

    /// 回归：从第三方切到官方 GPT 后，历史里的 bare reasoning item 会让官方后端回
    /// 404 "Item with id 'rs_…' not found"；转发前必须清掉，并校正 content-length。
    func test_openAIResponses_dropsBareReasoningBeforeForwarding() throws {
        let body = #"{"model":"deepseek-reasoner","store":false,"input":[{"type":"reasoning","id":"rs_old","summary":[]},{"type":"message","role":"user"}]}"#
        let response = proxy.handle(post("/v1/responses", body: body))
        XCTAssertEqual(response.statusCode, 200)
        let sent = try XCTUnwrap(forwarder.lastRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let items = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["type"] as? String, "message")
        XCTAssertEqual(sent.head.contentLength, sent.body.count)
    }

    func test_openAIResponses_keepsReasoningWhenStoreIsTrue() {
        let body = #"{"model":"deepseek-reasoner","store":true,"input":[{"type":"reasoning","id":"rs_old","summary":[]}]}"#
        _ = proxy.handle(post("/v1/responses", body: body))
        XCTAssertEqual(forwarder.lastRequest?.body, Data(body.utf8))
    }

    /// 回归：第三方明文推理的 `content` 发给官方后端会被 400 拒绝
    /// （`Expected an array with maximum length 0`），官方目标转发前必须摘掉。
    func test_openAIResponses_officialTargetDropsReasoningContent() throws {
        let official = AggregationProxyTarget(
            key: "openai", profileID: "official",
            baseURL: "https://chatgpt.com/backend-api/codex",
            token: "", passesThroughAuthorization: true
        )
        let officialProxy = AggregationProxy(
            resolver: AggregationTargetResolver(
                stack: .init(enabled: true, members: [], keys: [:]),
                registry: AggregationKeyRegistry(keys: [:]),
                profiles: [],
                defaultTarget: official
            ),
            modelLister: StubModelLister(),
            forwarder: forwarder,
            sealStore: sealStore
        )
        let body = #"{"model":"gpt-6.1-sol","input":[{"type":"reasoning","id":"rs_ds","summary":[],"content":[{"type":"reasoning_text","text":"raw"}],"encrypted_content":"sealed"},{"type":"message","role":"user"}]}"#
        _ = officialProxy.handle(post("/v1/responses", body: body))
        let sent = try XCTUnwrap(forwarder.lastRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let items = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertNil(items[0]["content"])
        XCTAssertEqual(items[0]["encrypted_content"] as? String, "sealed")
        XCTAssertEqual(sent.head.contentLength, sent.body.count)
    }

    /// 该目标此前拒绝过别家的 sealed reasoning：后续请求转发前直接去掉，不再每轮失败。
    func test_openAIResponses_precleansSealRefusedByTarget() throws {
        let body = #"{"model":"deepseek-reasoner","input":[{"type":"reasoning","id":"rs_1","encrypted_content":"sealed-x"},{"type":"message","role":"user"}]}"#
        sealStore.record(
            targetKey: "deepseek",
            seals: AggregationSealSanitizer.seals(in: Data(body.utf8))
        )

        _ = proxy.handle(post("/v1/responses", body: body))
        let sent = try XCTUnwrap(forwarder.lastRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let items = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["type"] as? String, "message")
    }

    func test_prefixedModel_rewritesBodyModelToUpstreamNameBeforeForwarding() {
        _ = proxy.handle(post("/v1/messages", body: #"{"model":"om-claude-kimi--k3"}"#))
        XCTAssertEqual(forwarder.lastTarget, kimiTarget)
        let sent = try? JSONSerialization.jsonObject(with: forwarder.lastRequest!.body) as? [String: Any]
        XCTAssertEqual(sent?["model"] as? String, "k3")
    }

    func test_passthroughEndpoint_forwardsVerbatimWithoutDecodingPrefixedModel() {
        // alpha/images 是透明端点（SPEC §9）：体里的 `om-` 聚合 id 也不解码，原样转发默认那家。
        let body = #"{"model":"om-kimi/k3","prompt":"cat"}"#
        let response = proxy.handle(post("/alpha/search", body: body))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(forwarder.lastProtocol, .codexPassthrough)
        XCTAssertEqual(forwarder.lastTarget, defaultTarget)
        XCTAssertEqual(forwarder.lastRequest?.body, Data(body.utf8))
    }

    func test_passthroughEndpoint_withoutDefaultTarget_returns503Not400() throws {
        // 无默认目标 → 503（对齐 cc-switch NoProvidersConfigured），不是解码路径的 400。
        let noDefaultProxy = AggregationProxy(
            resolver: AggregationTargetResolver(
                stack: .init(enabled: true, members: ["kimi"], keys: ["kimi": "kimi"]),
                registry: AggregationKeyRegistry(keys: ["kimi": "kimi"]),
                profiles: [],
                defaultTarget: nil
            ),
            modelLister: StubModelLister(),
            forwarder: forwarder
        )
        let response = noDefaultProxy.handle(post("/alpha/search", body: #"{"prompt":"cat"}"#))
        XCTAssertEqual(response.statusCode, 503)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
    }

    func test_miss_returns400WithAnthropicEnvelope() throws {
        let response = proxy.handle(post("/v1/messages", body: #"{"model":"om-claude-nobody--x"}"#))
        XCTAssertEqual(response.statusCode, 400)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "error")
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertTrue((error["message"] as? String)?.contains("OmniForge") == true)
    }

    func test_miss_returns400WithOpenAIEnvelopeForCodex() throws {
        let response = proxy.handle(post("/v1/responses", body: #"{"model":"om-nobody/x"}"#))
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

// MARK: - Claude Desktop（鉴权 + 列表形状 + plain 改写）

extension AggregationProxyTests {
    private func makeDesktopProxy(
        token: String?,
        routes: [String: DesktopModelRoute]?,
        published: [AggregationPublishedModel] = []
    ) -> AggregationProxy {
        let glm = ProviderProfile(
            id: "glm",
            name: "智谱",
            tool: .claudeDesktop,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-glm",
            desktopModelRoutes: routes
        )
        let proxy = AggregationProxy(
            resolver: AggregationTargetResolver(
                stack: .init(enabled: true, members: ["glm"], keys: ["glm": "glm"]),
                registry: AggregationKeyRegistry(keys: ["glm": "glm"]),
                profiles: [glm],
                defaultTarget: AggregationProxyTarget(
                    key: "glm", profileID: "glm",
                    baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
                ),
                published: published
            ),
            modelLister: StubModelLister(),
            forwarder: forwarder,
            sealStore: sealStore
        )
        proxy.desktopGatewayTokenProvider = { token }
        proxy.desktopRouteTableProvider = { routes }
        return proxy
    }

    private func desktopRequest(path: String, body: String, token: String?) -> AggregationHTTPRequest {
        var headers = ["content-type": "application/json"]
        if let token {
            headers["authorization"] = "Bearer \(token)"
        }
        return AggregationHTTPRequest(
            head: AggregationRequestHead(
                method: path.hasSuffix("models") ? "GET" : "POST",
                path: path,
                query: "",
                headers: headers,
                contentLength: Data(body.utf8).count
            ),
            body: Data(body.utf8)
        )
    }

    func test_desktop_returns401WhenTokenMissing() {
        let proxy = makeDesktopProxy(token: nil, routes: nil)
        let response = proxy.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"claude-sonnet-5"}"#, token: nil))
        XCTAssertEqual(response.statusCode, 401)
    }

    func test_desktop_returns401WhenTokenMismatched() {
        let proxy = makeDesktopProxy(token: "ccs-correct", routes: nil)
        let response = proxy.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"claude-sonnet-5"}"#, token: "ccs-wrong"))
        XCTAssertEqual(response.statusCode, 401)
        // 快照无 token 时带任何 Authorization 也一律 401。
        let noSnapshot = makeDesktopProxy(token: nil, routes: nil)
        XCTAssertEqual(noSnapshot.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"x"}"#, token: "ccs-anything")).statusCode, 401)
    }

    func test_desktop_modelsEndpointReturnsDesktopShapeWithSupports1M() throws {
        let entry = AggregationPublishedModel(
            tool: .claudeDesktop, key: "glm", profileName: "智谱",
            model: "glm-5.3", upstream: "glm-5.3", displayName: "GLM 5.3",
            oneM: true, window: 0
        )
        let proxy = makeDesktopProxy(token: "ccs-t", routes: nil, published: [entry])
        let response = proxy.handle(desktopRequest(path: "/claude-desktop/v1/models", body: "", token: "ccs-t"))
        XCTAssertEqual(response.statusCode, 200)
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])
        let data = try XCTUnwrap(root["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data[0]["id"] as? String, entry.id)
        XCTAssertEqual(data[0]["supports1m"] as? Bool, true)
        XCTAssertNotNil(data[0]["created_at"], "Desktop 形状必须带 created_at")
        XCTAssertEqual((data[0]["display_name"] as? String)?.contains("智谱"), true)
        XCTAssertEqual(root["has_more"] as? Bool, false)
    }

    func test_desktop_plainModelRewrittenByMappingCard() throws {
        let routes = [
            "claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
        ]
        let proxy = makeDesktopProxy(token: "ccs-t", routes: routes)
        let response = proxy.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"claude-sonnet-5"}"#, token: "ccs-t"))
        XCTAssertEqual(response.statusCode, 200)
        let forwardedBody = try XCTUnwrap((try? JSONSerialization.jsonObject(with: forwarder.lastRequest?.body ?? Data())) as? [String: Any])
        XCTAssertEqual(forwardedBody["model"] as? String, "glm-5.3", "映射卡必须把档名改写为上游真实名")
    }

    func test_desktop_plainModelPassesThroughWithoutMappingCard() throws {
        let proxy = makeDesktopProxy(token: "ccs-t", routes: nil)
        _ = proxy.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"claude-sonnet-4-20250514"}"#, token: "ccs-t"))
        let forwardedBody = try XCTUnwrap((try? JSONSerialization.jsonObject(with: forwarder.lastRequest?.body ?? Data())) as? [String: Any])
        XCTAssertEqual(forwardedBody["model"] as? String, "claude-sonnet-4-20250514", "直连卡对 Claude-safe 名原样透传")
    }

    func test_desktop_unconfiguredRoleReturns400() {
        let routes = [
            "claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
        ]
        let proxy = makeDesktopProxy(token: "ccs-t", routes: routes)
        let response = proxy.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"claude-haiku-4-5"}"#, token: "ccs-t"))
        XCTAssertEqual(response.statusCode, 400)
        let body = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("模型路由未配置"), "错误信息应含未配置的模型名：\(body)")
    }

    func test_desktop_publishedStackModelRoutesToMember() throws {
        let entry = AggregationPublishedModel(
            tool: .claudeDesktop, key: "glm", profileName: "智谱",
            model: "glm-5.3", upstream: "glm-5.3", displayName: "GLM 5.3",
            oneM: false, window: 0
        )
        let proxy = makeDesktopProxy(token: "ccs-t", routes: nil, published: [entry])
        _ = proxy.handle(desktopRequest(path: "/claude-desktop/v1/messages", body: #"{"model":"\(entry.id)"}"#, token: "ccs-t"))
        let forwardedBody = try XCTUnwrap((try? JSONSerialization.jsonObject(with: forwarder.lastRequest?.body ?? Data())) as? [String: Any])
        XCTAssertEqual(forwardedBody["model"] as? String, "glm-5.3", "聚合 id 反查后改写为上游真实名")
        XCTAssertEqual(forwarder.lastTarget?.key, "glm")
    }
}
