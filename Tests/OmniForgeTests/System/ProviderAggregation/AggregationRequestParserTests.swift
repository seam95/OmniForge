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
}
