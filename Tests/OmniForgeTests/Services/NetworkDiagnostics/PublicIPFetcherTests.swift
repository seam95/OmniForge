import Foundation
import XCTest
@testable import OmniForge

// MARK: - Fake HTTP client

final class FakeHTTPDataFetcher: HTTPDataFetching {
    enum Behavior {
        case success(body: String, status: Int)
        case failure(Error)
        case hang(seconds: TimeInterval)
    }

    var behavior: Behavior
    private(set) var requestedURLs: [URL] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        switch behavior {
        case let .success(body, status):
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case let .hang(seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
    }
}

final class PublicIPFetcherTests: XCTestCase {

    func test_fetchIPv4_success() async {
        let client = FakeHTTPDataFetcher(behavior: .success(body: "203.0.113.50\n", status: 200))
        let fetcher = PublicIPFetcher(client: client)
        let ip = await fetcher.fetchIPv4()
        XCTAssertEqual(ip, "203.0.113.50")
        XCTAssertEqual(client.requestedURLs, [PublicIPFetcher.ipv4URL])
    }

    func test_fetchIPv6_success() async {
        let client = FakeHTTPDataFetcher(behavior: .success(body: "2001:db8::1", status: 200))
        let fetcher = PublicIPFetcher(client: client)
        let ip = await fetcher.fetchIPv6()
        XCTAssertEqual(ip, "2001:db8::1")
        XCTAssertEqual(client.requestedURLs, [PublicIPFetcher.ipv6URL])
    }

    func test_fetch_timeoutReturnsNil() async {
        let client = FakeHTTPDataFetcher(behavior: .failure(URLError(.timedOut)))
        let fetcher = PublicIPFetcher(client: client)
        let ip = await fetcher.fetchIPv4()
        XCTAssertNil(ip)
    }

    func test_fetch_non200ReturnsNil() async {
        let client = FakeHTTPDataFetcher(behavior: .success(body: "203.0.113.1", status: 503))
        let fetcher = PublicIPFetcher(client: client)
        let ip = await fetcher.fetchIPv4()
        XCTAssertNil(ip)
    }

    func test_fetch_invalidBodyReturnsNil() async {
        let cases = [
            "not-an-ip",
            "<html>error</html>",
            "hello world",
            "",
            "example.com",
        ]
        for body in cases {
            let client = FakeHTTPDataFetcher(behavior: .success(body: body, status: 200))
            let fetcher = PublicIPFetcher(client: client)
            let ip = await fetcher.fetchIPv4()
            XCTAssertNil(ip, "expected nil for body: \(body)")
        }
    }

    func test_validatedIP_acceptsIPv4OnlyForPreferIPv4() {
        XCTAssertEqual(PublicIPFetcher.validatedIP("8.8.8.8", preferIPv4: true), "8.8.8.8")
        XCTAssertNil(PublicIPFetcher.validatedIP("2001:db8::1", preferIPv4: true))
        XCTAssertEqual(PublicIPFetcher.validatedIP("2001:db8::1", preferIPv4: false), "2001:db8::1")
        XCTAssertEqual(PublicIPFetcher.validatedIP("1.2.3.4", preferIPv4: false), "1.2.3.4")
    }
}
