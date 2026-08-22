import Foundation
import XCTest
@testable import OmniForge

/// Cursor 网页 API 客户端：浏览器伪装头集中定义、手动重定向（仅 cursor.com 域转发 cookie —
/// 安全红线，SPEC 6 / 参考 08 cursor-config.js:155-158）、401/403 → reauth、429 → retryAt。
final class CursorWebAPIClientTests: XCTestCase {
    private var fixedNow: Date!
    private var client: CursorWebAPIClient!

    override func setUp() {
        super.setUp()
        fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        client = CursorWebAPIClient(now: { self.fixedNow }, session: URLProtocolStub.makeSession())
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func curlHeaders() -> [String: String] {
        CursorBrowserHeaders.headers(cookie: "WorkosCursorSessionToken=user%3A%3Ajwt", accept: "application/json")
    }

    // MARK: - 浏览器伪装头（集中定义）

    func test_browserHeaders_carryUACookieRefererAccept() {
        let headers = curlHeaders()
        XCTAssertEqual(headers["Cookie"], "WorkosCursorSessionToken=user%3A%3Ajwt")
        XCTAssertTrue(headers["User-Agent"]?.contains("Mozilla/5.0") ?? false, "伪装 Chrome UA 过 Cloudflare")
        XCTAssertEqual(headers["Referer"], "https://www.cursor.com/settings")
        XCTAssertEqual(headers["Accept"], "application/json")
    }

    // MARK: - 重定向：仅 cursor.com 域（含子域）转发 cookie

    func test_getJSON_followsSingleHopToCursorComSubdomain_withCookieForwarded() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.host == "cursor.com" {
                return .init(statusCode: 302, headers: ["Location": "https://www.cursor.com/api/usage-summary"])
            }
            return .init(statusCode: 200, data: self.jsonData(["ok": true]))
        }
        let object = try await client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: curlHeaders())
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "手动跟一跳")
        XCTAssertEqual(URLProtocolStub.recordedRequests[1].url?.host, "www.cursor.com")
        XCTAssertEqual(
            URLProtocolStub.recordedRequests[1].value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user%3A%3Ajwt",
            "子域名目标是 cursor.com 域，可转发会话 cookie"
        )
    }

    func test_getJSON_followsRelativeLocation_resolvedAgainstBase() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/usage-summary" && request.url?.host == "cursor.com" {
                return .init(statusCode: 302, headers: ["Location": "preview/usage"])
            }
            return .init(statusCode: 200, data: self.jsonData(["ok": true]))
        }
        let object = try await client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: curlHeaders())
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(URLProtocolStub.recordedRequests[1].url?.path, "/api/preview/usage")
        XCTAssertEqual(URLProtocolStub.recordedRequests[1].url?.host, "cursor.com")
        XCTAssertNotNil(URLProtocolStub.recordedRequests[1].value(forHTTPHeaderField: "Cookie"))
    }

    func test_getJSON_crossHostRedirectAborts_withoutForwardingCookie() async {
        URLProtocolStub.stub = .init(statusCode: 302, headers: ["Location": "https://evil.example.com/steal"])
        do {
            _ = try await client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: curlHeaders())
            XCTFail("外域重定向必须终止")
        } catch let error as LimitError {
            guard case .network = error else {
                XCTFail("unexpected \(error)")
                return
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1, "绝不向站外发起任何请求")
        XCTAssertEqual(URLProtocolStub.recordedRequests[0].url?.host, "cursor.com", "只有原站的第一次请求")
    }

    func test_getJSON_crossHostRedirect_nothingElseTouchesNetwork_evenAfterRetry() async {
        // 连续两次调度都被拒绝（防泄漏短路），不是仅第一次碰运气。
        URLProtocolStub.stub = .init(statusCode: 302, headers: ["Location": "https://attacker.example.com/x"])
        for _ in 0..<2 {
            do {
                _ = try await client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: curlHeaders())
            } catch {
                // expected
            }
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "每次都只有原站一次请求，cookie 从未外泄")
    }

    func test_getJSON_redirectToNonHttpsRejected() async {
        URLProtocolStub.stub = .init(statusCode: 302, headers: ["Location": "http://cursor.com/not-tls"])
        await assertThrowsNetwork {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)
    }

    func test_getJSON_redirectWithoutLocationRejected() async {
        URLProtocolStub.stub = .init(statusCode: 302)
        await assertThrowsNetwork {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)
    }

    func test_getJSON_redirectChainDeepStopsAtOneHop() async {
        URLProtocolStub.handler = { request in
            if request.url?.host == "www.cursor.com" {
                return .init(statusCode: 302, headers: ["Location": "https://www.cursor.com/again"])
            }
            return .init(statusCode: 302, headers: ["Location": "https://www.cursor.com/next"])
        }
        await assertThrowsNetwork {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "只允许跟一跳，第二跳仍是 3xx → 终止")
    }

    // MARK: - 状态映射

    func test_getJSON_401MapsToReauth() async {
        URLProtocolStub.stub = .init(statusCode: 401)
        await assertThrowsLimitError(.reauthRequired) {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
    }

    func test_getJSON_429MapsToRateLimitedWithRetryAfter() async {
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "120"])
        await assertThrowsLimitError(.rateLimited(retryAt: fixedNow.addingTimeInterval(120))) {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
    }

    func test_getJSON_5xxMapsToNetwork() async {
        URLProtocolStub.stub = .init(statusCode: 503)
        await assertThrowsNetwork {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
    }

    func test_getJSON_invalidJSONMapsToDecoding() async {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("[1,2]".utf8))
        await assertThrowsLimitError(.decoding("Non-object JSON")) {
            try await self.client.getJSON(url: CursorWebAPIClient.usageSummaryEndpoint, headers: self.curlHeaders())
        }
    }

    // MARK: - CSV（getText）

    func test_getText_returnsRawCSVText() async throws {
        let csv = "Date,Model,Total Tokens\n2026-01-01,gpt-4o,2"
        URLProtocolStub.stub = .init(statusCode: 200, data: Data(csv.utf8))
        let text = try await client.getText(url: CursorWebAPIClient.usageCSVEndpoint, headers: curlHeaders())
        XCTAssertEqual(text, csv)
    }

    func test_getText_followsSingleCursorDotComRedirect() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.host == "cursor.com" {
                return .init(statusCode: 308, headers: ["Location": "https://craft.cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens"])
            }
            return .init(statusCode: 200, data: Data("Date,Model\n2026-01-01,x".utf8))
        }
        let text = try await client.getText(url: CursorWebAPIClient.usageCSVEndpoint, headers: curlHeaders())
        XCTAssertEqual(text, "Date,Model\n2026-01-01,x")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2)
        XCTAssertEqual(URLProtocolStub.recordedRequests[1].url?.host, "craft.cursor.com", "子域 cursor.com 允许转发")
    }

    // MARK: - 工具

    private func assertThrowsNetwork(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected network error", file: file, line: line)
        } catch let error as LimitError {
            guard case .network = error else {
                XCTFail("expected network, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func assertThrowsLimitError(
        _ expected: LimitError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as LimitError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
