import XCTest
@testable import OmniForge

final class ProviderAPIClientTests: XCTestCase {
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private var fixedNow: Date!

    override func setUp() {
        super.setUp()
        fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        URLProtocolStub.stub = nil
    }

    override func tearDown() {
        URLProtocolStub.stub = nil
        super.tearDown()
    }

    private func makeClient() -> ProviderAPIClient {
        ProviderAPIClient(now: { self.fixedNow }, session: URLProtocolStub.makeSession())
    }

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func test_getJSON_returnsObjectOnSuccess() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: jsonData(["plan_type": "pro"]))
        let object = try await makeClient().getJSON(url: endpoint)
        XCTAssertEqual(object["plan_type"] as? String, "pro")
    }

    func test_getJSON_401MapsToReauth() async {
        URLProtocolStub.stub = .init(statusCode: 401)
        await assertThrowsLimitError(.reauthRequired) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_403MapsToReauth() async {
        URLProtocolStub.stub = .init(statusCode: 403)
        await assertThrowsLimitError(.reauthRequired) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_429UsesRetryAfterHeader() async {
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "120"])
        await assertThrowsLimitError(.rateLimited(retryAt: fixedNow.addingTimeInterval(120))) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_429WithoutHeaderDefaultsToFiveMinutes() async {
        URLProtocolStub.stub = .init(statusCode: 429)
        await assertThrowsLimitError(.rateLimited(retryAt: fixedNow.addingTimeInterval(300))) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_429CapsRetryAfterAtOneHour() async {
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "999999"])
        await assertThrowsLimitError(.rateLimited(retryAt: fixedNow.addingTimeInterval(3600))) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_5xxMapsToNetwork() async {
        URLProtocolStub.stub = .init(statusCode: 500)
        await assertThrowsLimitError(.network("HTTP 500")) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_invalidJSONMapsToDecoding() async {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("[1,2]".utf8))
        await assertThrowsLimitError(.decoding("Non-object JSON")) {
            try await self.makeClient().getJSON(url: self.endpoint)
        }
    }

    func test_getJSON_transportErrorMapsToNetwork() async {
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.notConnectedToInternet))
        do {
            try await makeClient().getJSON(url: endpoint)
            XCTFail("expected network error")
        } catch let error as LimitError {
            guard case .network = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - POST（Gemini v1internal 半私有端点）

    func test_postJSON_sendsBodyAndHeaders_onSuccess() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 200, data: jsonData(["buckets": []]))
        let object = try await makeClient().postJSON(
            url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
            headers: ["Authorization": "Bearer t-1"],
            body: ["project": "projects/abc"]
        )
        XCTAssertTrue((object["buckets"] as? [[String: Any]])?.isEmpty ?? false)
        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let payload = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: URLProtocolStub.recordedBodies[0])) as? [String: Any]
        )
        XCTAssertEqual(payload["project"] as? String, "projects/abc")
    }

    func test_postJSON_401And429MapConsistently() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 401)
        await assertThrowsLimitError(.reauthRequired) {
            try await self.makeClient().postJSON(url: self.endpoint, headers: [:], body: [:])
        }

        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "60"])
        await assertThrowsLimitError(.rateLimited(retryAt: fixedNow.addingTimeInterval(60))) {
            try await self.makeClient().postJSON(url: self.endpoint, headers: [:], body: [:])
        }
    }

    func test_postJSON_transportErrorMapsToNetwork() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.notConnectedToInternet))
        do {
            try await makeClient().postJSON(url: endpoint, headers: [:], body: [:])
            XCTFail("expected network error")
        } catch let error as LimitError {
            guard case .network = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - 工具

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
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
