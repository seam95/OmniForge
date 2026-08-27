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

    // MARK: - client id / 过期判定

    func test_clientIDFromScopeKeySuffix() async throws {
        // 条目缺 oidc_client_id 时，scope 键 "<random>::<client-id>" 后缀兜底。
        try writeAuth(#"{"abc123::client-9":{"refresh_token":"r1"}}"#)
        network.refreshResult = ["access_token": "fresh-1"]
        network.billing = #"{"config":{"currentPeriod":{"type":"monthly","end":"2026-09-01T00:00:00Z"},"creditUsagePercent":10}}"#
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(network.lastPostBody?["client_id"], "client-9")
        XCTAssertEqual(network.lastBearer, "fresh-1")
    }

    func test_missingExpiry_treatedAsUnexpired() async throws {
        try writeAuth(#"{"xai-prod":{"key":"access-1"}}"#)
        network.billing = #"{"config":{"currentPeriod":{"type":"monthly","end":"2026-09-01T00:00:00Z"},"creditUsagePercent":10}}"#
        _ = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(network.postCount, 0, "expires_at 缺失视为未过期，不刷新")
    }

    func test_expiredWithoutRefreshCapability_usesOldKey() async throws {
        try writeAuth(#"{"xai-prod":{"key":"old","expires_at":1700000000}}"#)
        network.billing = #"{"config":{"currentPeriod":{"type":"monthly","end":"2026-09-01T00:00:00Z"},"creditUsagePercent":10}}"#
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result, "过期但无 refresh 能力 → 沿用旧 key 由 billing 裁决")
        XCTAssertEqual(network.lastBearer, "old")
    }

    // MARK: - 401 强制刷新重试 + 回写

    func test_billing401_forceRefreshesAndRetriesOnce() async throws {
        try writeAuth(#"{"xai-prod":{"key":"unexpired","expires_at":4102444800,"refresh_token":"r1","oidc_client_id":"c1"}}"#)
        network.refreshResult = ["access_token": "recovered-1", "refresh_token": "r2", "expires_in": 3600]
        network.billing = #"{"config":{"currentPeriod":{"type":"monthly","end":"2026-09-01T00:00:00Z"},"creditUsagePercent":50}}"#
        network.forceReauthOnFirstBilling = true
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.monthly]?.usedPercent, 50, "401 后强制刷新重试成功")
        XCTAssertEqual(network.postCount, 1)
        XCTAssertEqual(network.bearers, ["unexpired", "recovered-1"], "首次旧 key 401，重试用刷新后 key")
    }

    func test_refreshWritesBackAuthJSON() async throws {
        try writeAuth(#"{"xai-prod":{"key":"expired","expires_at":1700000000,"refresh_token":"r1","oidc_client_id":"c1"},"other-entry":{"foo":1}}"#)
        network.refreshResult = ["access_token": "fresh-1", "refresh_token": "r2", "expires_at": 4102_444_800]
        network.billing = #"{"config":{"currentPeriod":{"type":"monthly","end":"2026-09-01T00:00:00Z"},"creditUsagePercent":10}}"#
        _ = try await fetcher.fetchLimits(force: false)

        let data = try Data(contentsOf: homeDir.appendingPathComponent("auth.json"))
        let written = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let entry = written["xai-prod"] as! [String: Any]
        XCTAssertEqual(entry["key"] as? String, "fresh-1", "新 access key 回写")
        XCTAssertEqual(entry["refresh_token"] as? String, "r2", "轮换出的 refresh token 必须回写")
        XCTAssertEqual(entry["expires_at"] as? Int, 4102_444_800)
        XCTAssertNotNil(written["other-entry"], "其他条目原样保留")
    }

    func test_refreshWithoutExpiry_removesStaleExpiryField() async throws {
        try writeAuth(#"{"xai-prod":{"key":"expired","expires_at":1700000000,"refresh_token":"r1","oidc_client_id":"c1"}}"#)
        network.refreshResult = ["access_token": "fresh-1"]
        network.billing = #"{"config":{"currentPeriod":{"type":"monthly","end":"2026-09-01T00:00:00Z"},"creditUsagePercent":10}}"#
        _ = try await fetcher.fetchLimits(force: false)

        let data = try Data(contentsOf: homeDir.appendingPathComponent("auth.json"))
        let written = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let entry = written["xai-prod"] as! [String: Any]
        XCTAssertNil(entry["expires_at"], "过期时间未知时删除旧值，防每轮重复刷新")
    }

    // MARK: - 解析纯函数

    func test_primaryWindowKind_enumAndDurationInference() {
        let weeklyEnum: [String: Any] = ["config": ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY"]]]
        XCTAssertEqual(GrokLimitsParsing.primaryWindowKind(from: weeklyEnum), .weekly)
        let monthlyEnum: [String: Any] = ["config": ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY"]]]
        XCTAssertEqual(GrokLimitsParsing.primaryWindowKind(from: monthlyEnum), .monthly)
        // 未知类型 → 按周期时长推断：7 天 → 周。
        let duration: [String: Any] = ["config": ["currentPeriod": [
            "type": "unknown",
            "start": "2026-08-01T00:00:00Z", "end": "2026-08-08T00:00:00Z",
        ]]]
        XCTAssertEqual(GrokLimitsParsing.primaryWindowKind(from: duration), .weekly)
        let monthDuration: [String: Any] = ["config": ["currentPeriod": [
            "start": "2026-08-01T00:00:00Z", "end": "2026-08-31T00:00:00Z",
        ]]]
        XCTAssertEqual(GrokLimitsParsing.primaryWindowKind(from: monthDuration), .monthly)
    }

    func test_windows_acceptWrappedValNumbers() {
        let body: [String: Any] = ["config": [
            "currentPeriod": ["type": "monthly", "end": "2026-09-01T00:00:00Z"],
            "monthlyLimit": ["val": 200], "used": ["val": 50],
        ]]
        let (primary, _) = GrokLimitsParsing.windows(from: body)
        XCTAssertEqual(primary?.usedPercent, 25, "unified billing 的 {val:…} 包装数值可解")
    }
}

// MARK: - 测试替身

private final class FakeGrokNetwork: GrokNetworkServicing {
    var billing: String?
    var legacyBilling: String?
    var refreshResult: [String: Any] = [:]
    var billingError: Error?
    var refreshError: Error?
    /// 首次 billing 请求抛 reauthRequired（模拟服务端提前吊销）。
    var forceReauthOnFirstBilling = false
    private(set) var postCount = 0
    private(set) var getCount = 0
    private(set) var lastPostURL: URL?
    private(set) var lastPostBody: [String: String]?
    private(set) var lastBearer: String?
    private(set) var bearers: [String] = []

    func postForm(url: URL, body: [String: String]) async throws -> [String: Any] {
        postCount += 1
        lastPostURL = url
        lastPostBody = body
        if let refreshError { throw refreshError }
        return refreshResult
    }

    func getJSON(url: URL, bearer: String) async throws -> [String: Any] {
        getCount += 1
        lastBearer = bearer
        bearers.append(bearer)
        let isCredits = url.absoluteString.contains("format=credits")
        if isCredits, forceReauthOnFirstBilling, bearers.filter({ $0 == bearers.first }).count == 1 {
            forceReauthOnFirstBilling = false
            throw LimitError.reauthRequired
        }
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