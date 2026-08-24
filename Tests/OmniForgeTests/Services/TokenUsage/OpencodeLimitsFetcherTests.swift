import Foundation
import XCTest
@testable import OmniForge

/// opencode Go 限额 fetcher：API key 环境变量守卫、rolling/weekly/monthly 窗口。
final class OpencodeLimitsFetcherTests: XCTestCase {

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
    }

    private func makeFetcher(apiKey: String? = "test-key") -> OpencodeLimitsFetcher {
        var environment: [String: String] = [:]
        if let apiKey { environment["OPENCODE_GO_API_KEY"] = apiKey }
        return OpencodeLimitsFetcher(session: URLProtocolStub.makeSession(), environment: environment)
    }

    func test_noApiKey_returnsNilWithoutNetwork() async throws {
        URLProtocolStub.stub = .init(statusCode: 500) // 不应被触达
        let result = try await makeFetcher(apiKey: nil).fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "无 key 零网络请求")
    }

    func test_validKey_buildsThreeWindows() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"rollingUsage":{"usagePercent":0.2,"resetInSec":3600},\
        "weeklyUsage":{"usagePercent":55,"resetInSec":604800},\
        "monthlyUsage":{"usagePercent":80,"resetInSec":2592000}}
        """.utf8))
        let result = try await makeFetcher().fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 20, "0.2 小数 → 20%")
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent, 55)
        XCTAssertEqual(result?.windows[.monthly]?.usedPercent, 80)
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request?.url?.absoluteString, "https://opencode.ai/zen/go/v1/usage")
    }

    func test_unauthorized_throwsReauth() async {
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await makeFetcher().fetchLimits(force: false)
            XCTFail("401 → 应抛 reauth")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_emptyWindows_returnsNil() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("{}".utf8))
        let result = try await makeFetcher().fetchLimits(force: false)
        XCTAssertNil(result, "无窗口 → 不显示限额卡")
    }
}