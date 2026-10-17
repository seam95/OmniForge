import XCTest
@testable import OmniForge

/// 模型发现端点：Anthropic 形状响应体（有序、display_name/description 口径）、
/// 空列表合法；内容协商判定（anthropic-version 头或 limit query，排除 client_version）。
final class AggregationModelDiscoveryTests: XCTestCase {
    private func makePublished(
        key: String,
        profileName: String = "Kimi For Coding",
        model: String,
        displayName: String? = nil,
        window: UInt64 = 256_000
    ) -> AggregationPublishedModel {
        AggregationPublishedModel(
            key: key,
            profileName: profileName,
            model: model,
            upstream: model,
            displayName: displayName ?? model,
            oneM: false,
            window: window
        )
    }

    private var kimiK3: AggregationPublishedModel {
        makePublished(key: "kimi", model: "k3", displayName: "Kimi K3")
    }

    private var zhipuGLM: AggregationPublishedModel {
        makePublished(key: "zhipu", profileName: "Zhipu", model: "glm-5.2", displayName: "GLM 5.2")
    }

    func test_responseBody_isAnthropicShapedAndOrdered() throws {
        let body = AggregationModelDiscovery.responseBody(published: [kimiK3, zhipuGLM])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["has_more"] as? Bool, false)
        let data = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(data.map { $0["type"] as? String }, ["model", "model"])
        XCTAssertEqual(data.map { $0["id"] as? String }, ["om-claude-kimi--k3", "om-claude-zhipu--glm-5.2"])
        XCTAssertEqual(data[0]["display_name"] as? String, "Kimi K3（Kimi For Coding）")
        XCTAssertEqual(data[0]["description"] as? String, "k3 · 256K")
    }

    func test_responseBody_emptyListIsValid() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: AggregationModelDiscovery.responseBody(published: [])) as? [String: Any])
        XCTAssertEqual((json["data"] as? [[String: Any]])?.count, 0)
    }

    func test_isModelDiscoveryRequest_requiresAnthropicVersionOrLimitQuery() {
        XCTAssertTrue(AggregationModelDiscovery.isModelDiscoveryRequest(
            method: "GET", path: "/v1/models", headers: ["anthropic-version": "2023-06-01"], query: ""))
        XCTAssertTrue(AggregationModelDiscovery.isModelDiscoveryRequest(
            method: "GET", path: "/v1/models", headers: [:], query: "limit=10"))
        XCTAssertFalse(AggregationModelDiscovery.isModelDiscoveryRequest(
            method: "GET", path: "/v1/models", headers: [:], query: "client_version=1"))
        XCTAssertFalse(AggregationModelDiscovery.isModelDiscoveryRequest(
            method: "POST", path: "/v1/models", headers: [:], query: ""))
    }
}
