import Foundation
import XCTest
@testable import OmniForge

/// 供应商连通性测试器：URL 候选构建（移植 cc-switch 口径）、双形状响应解析、
/// 三态判定（成功/鉴权失败/端点缺失/网络失败/服务端错误）与凭证脱敏。
final class ProviderConnectivityTesterTests: XCTestCase {

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
    }

    // MARK: - URL 候选构建

    func test_candidates_plainBase_appendsV1Models() {
        XCTAssertEqual(
            ProviderModelsEndpointBuilder.candidates(baseURL: "https://api.example.com"),
            ["https://api.example.com/v1/models"]
        )
    }

    func test_candidates_v1Suffix_usesModelsOnly() {
        // /v1 结尾：版本号已在路径里，不能再补 /v1。
        XCTAssertEqual(
            ProviderModelsEndpointBuilder.candidates(baseURL: "https://api.example.com/v1/"),
            ["https://api.example.com/v1/models"]
        )
    }

    func test_candidates_v4Suffix_keepsV1Fallback() {
        // 智谱风格 /v{N}（N≠1）：正确路径在前，/v1/models 兜底在后。
        XCTAssertEqual(
            ProviderModelsEndpointBuilder.candidates(baseURL: "https://open.bigmodel.cn/api/coding/paas/v4"),
            [
                "https://open.bigmodel.cn/api/coding/paas/v4/models",
                "https://open.bigmodel.cn/api/coding/paas/v4/v1/models",
            ]
        )
    }

    func test_candidates_anthropicCompatSuffix_appendsStrippedVariants() {
        // Anthropic 兼容子路径：剥离后缀追加两种变体（去重保序）。
        XCTAssertEqual(
            ProviderModelsEndpointBuilder.candidates(baseURL: "https://open.bigmodel.cn/api/anthropic"),
            [
                "https://open.bigmodel.cn/api/anthropic/v1/models",
                "https://open.bigmodel.cn/v1/models",
                "https://open.bigmodel.cn/models",
            ]
        )
    }

    func test_candidates_emptyBase_returnsNil() {
        XCTAssertNil(ProviderModelsEndpointBuilder.candidates(baseURL: "  "))
        XCTAssertNil(ProviderModelsEndpointBuilder.candidates(baseURL: ""))
    }

    func test_versionSegmentDetection() {
        XCTAssertTrue(ProviderModelsEndpointBuilder.endsWithVersionSegment("https://a.com/v1"))
        XCTAssertTrue(ProviderModelsEndpointBuilder.endsWithVersionSegment("https://a.com/v12"))
        XCTAssertFalse(ProviderModelsEndpointBuilder.endsWithVersionSegment("https://a.com/vN"))
        XCTAssertFalse(ProviderModelsEndpointBuilder.endsWithVersionSegment("https://a.com/v123"))
        XCTAssertFalse(ProviderModelsEndpointBuilder.endsWithVersionSegment("https://a.com/models"))
    }

    // MARK: - 响应解析

    func test_decoder_openAIShape() {
        let data = Data(#"{"data":[{"id":"gpt-5.6"},{"id":"gpt-5.6-mini"},{"id":"","owned_by":"x"}]}"#.utf8)
        XCTAssertEqual(ProviderModelsResponseDecoder.modelIDs(from: data), ["gpt-5.6", "gpt-5.6-mini"])
    }

    func test_decoder_catalogSlugShape() {
        let data = Data(#"{"models":[{"slug":"glm-5.3"},{"slug":"glm-4.7-air"}]}"#.utf8)
        XCTAssertEqual(ProviderModelsResponseDecoder.modelIDs(from: data), ["glm-5.3", "glm-4.7-air"])
    }

    func test_decoder_unrecognizedShape_returnsNil() {
        XCTAssertNil(ProviderModelsResponseDecoder.modelIDs(from: Data(#"{"error":"nope"}"#.utf8)))
        XCTAssertNil(ProviderModelsResponseDecoder.modelIDs(from: Data(#"{"data":[]}"#.utf8)))
        XCTAssertNil(ProviderModelsResponseDecoder.modelIDs(from: Data("<html>404</html>".utf8)))
    }

    // MARK: - 判定（注入 URLProtocolStub session）

    private func makeTester() -> ProviderConnectivityTester {
        ProviderConnectivityTester(client: URLProtocolStub.makeSession())
    }

    func test_success_carriesModelsAndBearerHeader() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-live-key"
            )
            return .init(statusCode: 200, data: Data(#"{"data":[{"id":"gpt-5.6"}]}"#.utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://api.example.com", token: "sk-live-key", tool: .codex
        )
        XCTAssertEqual(result.outcome, .success(models: ["gpt-5.6"]))
        XCTAssertNotNil(result.latencyMilliseconds)
    }

    func test_claudeTool_sendsAnthropicVersionHeader() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            return .init(statusCode: 200, data: Data(#"{"data":[{"id":"glm-5.3"}]}"#.utf8))
        }
        let result = await makeTester().test(
            baseURL: "https://relay.example.com/api/anthropic", token: "k", tool: .claudeCode
        )
        XCTAssertTrue(result.isSuccess)
    }

    func test_authRejected_401() async {
        URLProtocolStub.stub = .init(statusCode: 401, data: Data())
        let result = await makeTester().test(
            baseURL: "https://api.example.com", token: "bad", tool: .codex
        )
        XCTAssertEqual(result.outcome, .authRejected(status: 401))
    }

    func test_endpoint404_advancesToNextCandidate_thenEndpointMissing() async {
        // 全部候选 404 → 推进耗尽 → endpointMissing（请求按候选顺序发出）。
        URLProtocolStub.handler = { _ in .init(statusCode: 404, data: Data()) }
        let result = await makeTester().test(
            baseURL: "https://api.example.com/api/anthropic", token: "k", tool: .claudeCode
        )
        XCTAssertEqual(result.outcome, .endpointMissing)
        let urls = URLProtocolStub.recordedRequests.compactMap(\.url?.absoluteString)
        XCTAssertEqual(urls.first, "https://api.example.com/api/anthropic/v1/models")
        XCTAssertEqual(urls.last, "https://api.example.com/models")
    }

    func test_serverError_bodyTruncatedAndTokenRedacted() async {
        let secret = "sk-secret-abc123"
        let longBody = String(repeating: "x", count: 2000) + secret
        URLProtocolStub.stub = .init(statusCode: 502, data: Data(longBody.utf8))
        let result = await makeTester().test(
            baseURL: "https://api.example.com", token: secret, tool: .codex
        )
        guard case .serverError(let status, let body) = result.outcome else {
            return XCTFail("期望 serverError，实际 \(result.outcome)")
        }
        XCTAssertEqual(status, 502)
        XCTAssertEqual(body.count, ProviderConnectivityTester.errorBodyLimit)
        XCTAssertFalse(body.contains(secret), "错误信息不得回显凭证")
    }

    func test_networkError_failsWithoutRetryingOtherCandidates() async {
        // 网络级错误直接失败（同一台服务器换路径也到不了），不再推进候选。
        URLProtocolStub.stub = .init(statusCode: 0, data: Data(), error: URLError(.timedOut))
        let result = await makeTester().test(
            baseURL: "https://api.example.com", token: "k", tool: .codex
        )
        guard case .networkFailure = result.outcome else {
            return XCTFail("期望 networkFailure，实际 \(result.outcome)")
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)
    }

    func test_emptyInputs_failFastWithoutRequests() async {
        let result = await makeTester().test(baseURL: "  ", token: "k", tool: .codex)
        guard case .networkFailure = result.outcome else {
            return XCTFail("期望 networkFailure，实际 \(result.outcome)")
        }
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty)
    }

    func test_unparseable2xx_reportsServerError() async {
        // 2xx 但形状不符：按 cc-switch 口径直接报错，不推进候选。
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("<html>hi</html>".utf8))
        let result = await makeTester().test(
            baseURL: "https://api.example.com", token: "k", tool: .codex
        )
        guard case .serverError(let status, _) = result.outcome else {
            return XCTFail("期望 serverError，实际 \(result.outcome)")
        }
        XCTAssertEqual(status, 200)
    }
}
