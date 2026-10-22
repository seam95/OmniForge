import XCTest
@testable import OmniForge

/// 代理侧请求头解析：方法/路径/query/头（小写化、content-length）提取、
/// 头未收全返回 nil、缺 content-length 记 0；请求体取 model 字段。
final class AggregationRequestParserTests: XCTestCase {
    func test_parseHead_extractsMethodPathQueryAndHeaders() throws {
        let raw = "POST /v1/messages?limit=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Api-Key: PROXY_MANAGED\r\nContent-Length: 12\r\n\r\n"
        let head = try XCTUnwrap(AggregationRequestParser.parseHead(Data(raw.utf8)))
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.path, "/v1/messages")
        XCTAssertEqual(head.query, "limit=1")
        XCTAssertEqual(head.headers["x-api-key"], "PROXY_MANAGED")
        XCTAssertEqual(head.contentLength, 12)
    }

    func test_parseHead_returnsNilWhenHeaderIncomplete() {
        XCTAssertNil(AggregationRequestParser.parseHead(Data("POST /v1/messages HTTP/1.1\r\nHost: x\r\n".utf8)))
    }

    func test_parseHead_missingContentLengthIsZero() throws {
        let raw = "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertEqual(try XCTUnwrap(AggregationRequestParser.parseHead(Data(raw.utf8))).contentLength, 0)
    }

    func test_model_readsModelFieldFromBody() throws {
        XCTAssertEqual(AggregationRequestParser.model(from: Data(#"{"model":"om-claude-kimi--k3","max_tokens":1}"#.utf8)), "om-claude-kimi--k3")
    }

    func test_model_returnsNilForMalformedBody() {
        XCTAssertNil(AggregationRequestParser.model(from: Data("not json".utf8)))
        XCTAssertNil(AggregationRequestParser.model(from: Data(#"{"max_tokens":1}"#.utf8)))
    }

    // MARK: - 跨供应商 bare reasoning 清洗

    private func inputItems(_ body: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["input"] as? [[String: Any]])
    }

    /// 回归：store=false 时上一家的 reasoning item 只有 id + summary，
    /// 官方后端按 id 查不到会回 404 "Item with id 'rs_…' not found"。
    func test_removingBareReasoningItems_dropsUnpersistedReasoning() throws {
        let body = Data(#"""
        {"model":"gpt-5.6-sol","store":false,"input":[
          {"type":"message","role":"user","content":[]},
          {"type":"reasoning","id":"rs_old","summary":[]},
          {"type":"reasoning","id":"rs_sealed","summary":[],"encrypted_content":"sealed"},
          {"type":"function_call","call_id":"c1","name":"shell","arguments":"{}"}
        ]}
        """#.utf8)
        let items = try inputItems(AggregationRequestParser.removingBareReasoningItems(from: body))
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["rs_sealed"])
        XCTAssertEqual(items.first?["type"] as? String, "message")
        XCTAssertEqual(items.last?["type"] as? String, "function_call")
    }

    func test_removingBareReasoningItems_dropsWhenStoreMissing() throws {
        let body = Data(#"{"input":[{"type":"reasoning","id":"rs_old","summary":[]},{"type":"message","role":"user"}]}"#.utf8)
        let items = try inputItems(AggregationRequestParser.removingBareReasoningItems(from: body))
        XCTAssertEqual(items.count, 1)
    }

    func test_removingBareReasoningItems_keepsEverythingWhenStoreTrue() throws {
        let body = Data(#"{"store":true,"input":[{"type":"reasoning","id":"rs_old","summary":[]}]}"#.utf8)
        XCTAssertEqual(AggregationRequestParser.removingBareReasoningItems(from: body), body)
    }

    func test_removingBareReasoningItems_ignoresNonArrayInput() {
        let body = Data(#"{"store":false,"input":"hello"}"#.utf8)
        XCTAssertEqual(AggregationRequestParser.removingBareReasoningItems(from: body), body)
    }
}
