import Foundation
import XCTest
@testable import OmniForge

/// grok 限额 fetcher：auth.json 读取、OAuth 刷新、billing 窗口归一化、失败降级。
final class GrokLimitsFetcherTests: XCTestCase {
    private var homeDir: URL!
    private var network: FakeGrokNetwork!
    private var fetcher: GrokLimitsFetcher!

    override func setUpWithError() throws {
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokLimitsFetcherTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        network = FakeGrokNetwork()
        fetcher = GrokLimitsFetcher(network: network)
        fetcher.homeOverride = homeDir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: homeDir)
    }

    private func writeAuth(_ json: String) throws {
        try Data(json.utf8).write(to: homeDir.appendingPathComponent("auth.json"))
    }

    func test_missingAuth_returnsNil() async throws {
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertEqual(network.postCount + network.getCount, 0, "无凭证零网络请求")
    }

    func test_validAccessToken_buildsWindows() async throws {
        try writeAuth(#"{"xai-prod":{"key":"access-1","expires_at":4102444800,"refresh_token":"r1","oidc_client_id":"c1"}}"#)
        network.billing = """
        {"config":{"currentPeriod":{"type":"monthly","start":"2026-08-01T00:00:00Z","end":"2026-09-01T00:00:00Z"},\
        "creditUsagePercent":42,"onDemandCap":100,"onDemandUsed":30}}
        """
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.windows[.monthly]?.usedPercent, 42)
        XCTAssertEqual(result?.labeledWindows?.first?.label, "on-demand")
        XCTAssertEqual(result?.labeledWindows?.first?.window.usedPercent, 30)
        XCTAssertEqual(network.postCount, 0, "未过期 token 不刷新")
    }

    func test_expiredToken_refreshesViaOAuth() async throws {
        try writeAuth(#"{"xai-prod":{"key":"expired","expires_at":1700000000,"refresh_token":"r1","oidc_client_id":"c1"}}"#)
        network.refreshResult = ["access_token": "fresh-1"]
        network.billing = """
        {"config":{"currentPeriod":{"type":"weekly","end":"2026-08-31T00:00:00Z"},"creditUsagePercent":10}}
        """
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent, 10)
        XCTAssertEqual(network.postCount, 1, "过期 → OAuth 刷新一次")
        XCTAssertEqual(network.lastPostURL?.absoluteString, "https://auth.x.ai/oauth2/token")
        XCTAssertEqual(network.lastBearer, "fresh-1", "刷新后用新 token 取 billing")
    }

    func test_refreshRejected_throwsReauth() async throws {
        try writeAuth(#"{"xai-prod":{"key":"expired","expires_at":1700000000,"refresh_token":"r1","oidc_client_id":"c1"}}"#)
        network.refreshError = LimitError.reauthRequired
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("刷新被拒 → 应抛 reauth")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_legacyBillingFallback() async throws {
        try writeAuth(#"{"xai-prod":{"key":"access-1","expires_at":4102444800}}"#)
        network.billingError = LimitError.network("credits 500")
        network.legacyBilling = #"{"config":{"monthlyLimit":1000,"used":250}}"#
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 25, "legacy 计数兜底")
    }
}

// MARK: - 测试替身

private final class FakeGrokNetwork: GrokNetworkServicing {
    var billing: String?
    var legacyBilling: String?
    var refreshResult: [String: Any] = [:]
    var billingError: Error?
    var refreshError: Error?
    private(set) var postCount = 0
    private(set) var getCount = 0
    private(set) var lastPostURL: URL?
    private(set) var lastBearer: String?

    func postForm(url: URL, body: [String: String]) async throws -> [String: Any] {
        postCount += 1
        lastPostURL = url
        if let refreshError { throw refreshError }
        return refreshResult
    }

    func getJSON(url: URL, bearer: String) async throws -> [String: Any] {
        getCount += 1
        lastBearer = bearer
        let isCredits = url.absoluteString.contains("format=credits")
        if isCredits, let billingError { throw billingError }
        if isCredits, let billing {
            return try JSONSerialization.jsonObject(with: Data(billing.utf8)) as! [String: Any]
        }
        if let legacyBilling {
            return try JSONSerialization.jsonObject(with: Data(legacyBilling.utf8)) as! [String: Any]
        }
        throw LimitError.network("no stub")
    }
}