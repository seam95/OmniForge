import Foundation
import XCTest
@testable import OmniForge

/// StepFun Step Plan 限额：双模解析（滑动窗口 / Credit 池）、JWT device_id 提取、
/// 钥匙串 + 环境变量凭证解析、401→reauth 映射。
private final class FakeStepfunTokenStore: StepfunTokenStoring {
    var storedToken: String?
    var readError: Error?
    private(set) var readCount = 0

    func readToken() throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return storedToken
    }

    func writeToken(_ token: String) throws { storedToken = token }
    func deleteToken() throws { storedToken = nil }
}

final class StepfunLimitsFetcherTests: XCTestCase {
    private var tokenStore: FakeStepfunTokenStore!

    override func setUpWithError() throws {
        tokenStore = FakeStepfunTokenStore()
    }

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
    }

    // MARK: - JSON 夹具

    private func rollingWindowJSON(
        fiveHourLeft: String = "0.6",
        fiveHourReset: String = "1777528800",
        weeklyLeft: String = "0.9",
        weeklyReset: String = "1777615200"
    ) -> String {
        """
        {"five_hour_usage_left_rate":\(fiveHourLeft),"five_hour_usage_reset_time":\(fiveHourReset),\
        "weekly_usage_left_rate":\(weeklyLeft),"weekly_usage_reset_time":\(weeklyReset)}
        """
    }

    private func creditPoolJSON() -> String {
        """
        {"plan_family":2,"plan_credit_rate_limit":{"credit_buckets":[\
        {"credit_total":"400000000","credit_residual":"100000000","next_reset_at":"1777528800"},\
        {"credit_total":"200000000","credit_residual":"200000000"}]}}
        """
    }

    // MARK: - 滑动窗口解析

    func test_rollingWindow_parsesSessionAndWeekly() {
        let payload = try! JSONSerialization.jsonObject(with: Data(rollingWindowJSON().utf8)) as! [String: Any]
        let result = StepfunPlanParsing.parseLimits(rateLimitPayload: payload, capturedAt: Date())

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.provider, .stepfun)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.windows[.credits], nil, "滑动窗口型不得产出 credits 窗")
        // 已用百分比 = (1 - left) * 100
        XCTAssertEqual(result?.windows[.session]?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(result?.windows[.session]?.resetAt, Date(timeIntervalSince1970: 1_777_528_800))
        XCTAssertEqual(result?.windows[.session]?.windowSeconds, 18_000)
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(result?.windows[.weekly]?.resetAt, Date(timeIntervalSince1970: 1_777_615_200))
        XCTAssertEqual(result?.windows[.weekly]?.windowSeconds, 604_800)
        XCTAssertNil(result?.planLabel)
    }

    func test_rollingWindow_toleratesStringNumbersAndTimestamps() {
        // 高精度小数 + 满额 left=1 → 已用 0；验证字符串型数字/时间戳兼容。
        let payload = try! JSONSerialization.jsonObject(
            with: Data(rollingWindowJSON(fiveHourLeft: "0.9978", weeklyLeft: "1").utf8)
        ) as! [String: Any]
        let result = StepfunPlanParsing.parseLimits(rateLimitPayload: payload)

        XCTAssertEqual(result?.windows[.session]?.usedPercent ?? -1, 0.22, accuracy: 0.001)
        XCTAssertEqual(result?.windows[.session]?.resetAt, Date(timeIntervalSince1970: 1_777_528_800))
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent ?? -1, 0, accuracy: 0.001)
    }

    func test_planLabel_extractedFromStatus() {
        let payload = try! JSONSerialization.jsonObject(with: Data(rollingWindowJSON().utf8)) as! [String: Any]
        let status = try! JSONSerialization.jsonObject(
            with: Data(#"{"subscription":{"name":" Plus "}}"#.utf8)
        ) as! [String: Any]
        let result = StepfunPlanParsing.parseLimits(rateLimitPayload: payload, planStatusPayload: status)
        XCTAssertEqual(result?.planLabel, "Plus", "套餐名应 trim 空白")
    }

    // MARK: - Credit 额度池解析

    func test_creditPool_aggregatesBuckets() {
        let payload = try! JSONSerialization.jsonObject(with: Data(creditPoolJSON().utf8)) as! [String: Any]
        let result = StepfunPlanParsing.parseLimits(rateLimitPayload: payload)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.session], nil, "Credit 池型不得产出 session 窗")
        XCTAssertEqual(result?.windows[.weekly], nil)
        let credits = result?.windows[.credits]
        XCTAssertNotNil(credits)
        // 600M 总额 / 300M 剩余 → 已用 50%
        XCTAssertEqual(credits?.usedPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(credits?.limit, 600_000_000)
        XCTAssertEqual(credits?.used, 300_000_000)
        XCTAssertEqual(credits?.remaining, 300_000_000)
        XCTAssertEqual(credits?.unit, "Credit")
        XCTAssertEqual(credits?.resetAt, Date(timeIntervalSince1970: 1_777_528_800))
    }

    func test_creditPool_fallsBackToSubscriptionLeftRate() {
        let payload = try! JSONSerialization.jsonObject(
            with: Data(#"{"plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":"0.75"}}"#.utf8)
        ) as! [String: Any]
        let result = StepfunPlanParsing.parseLimits(rateLimitPayload: payload)
        let credits = result?.windows[.credits]
        XCTAssertEqual(credits?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertNil(credits?.limit, "无桶时无聚合额度")
        XCTAssertEqual(credits?.unit, "Credit")
    }

    func test_isCreditPlan_flagsPlanFamilyTwoWithoutWindow() {
        let credit: [String: Any] = ["plan_family": 2]
        XCTAssertTrue(StepfunPlanParsing.isCreditPlan(payload: credit))
        let rolling: [String: Any] = ["five_hour_usage_reset_time": 1_777_528_800, "plan_family": 2]
        XCTAssertFalse(StepfunPlanParsing.isCreditPlan(payload: rolling), "有活窗口时判为滑动窗口型")
    }

    func test_parseLimits_returnsNilWhenNoRecognizableFields() {
        let payload = try! JSONSerialization.jsonObject(with: Data(#"{"foo":"bar"}"#.utf8)) as! [String: Any]
        XCTAssertNil(StepfunPlanParsing.parseLimits(rateLimitPayload: payload))
    }

    // MARK: - JWT device_id 提取

    private func makeJWT(deviceID: String?) -> String {
        var payload: [String: Any] = [:]
        if let deviceID { payload["device_id"] = deviceID }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).signature"
    }

    func test_webID_extractsDeviceIDFromJWT() {
        XCTAssertEqual(StepfunWebIDExtractor.webID(forToken: makeJWT(deviceID: "dev-abc-123")), "dev-abc-123")
    }

    func test_webID_picksRefreshHalfWhenAccessLacksDeviceID() {
        // access...refresh 双 token：access 无 device_id，refresh 有；reversed 命中 refresh。
        let token = "\(makeJWT(deviceID: nil))...\(makeJWT(deviceID: "refresh-dev"))"
        XCTAssertEqual(StepfunWebIDExtractor.webID(forToken: token), "refresh-dev")
    }

    func test_webID_fallsBackToDefaultWhenNoDeviceID() {
        XCTAssertEqual(StepfunWebIDExtractor.webID(forToken: makeJWT(deviceID: nil)), StepfunWebIDExtractor.defaultWebID)
    }

    func test_webID_fallsBackToDefaultOnMalformedToken() {
        XCTAssertEqual(StepfunWebIDExtractor.webID(forToken: "not-a-jwt"), StepfunWebIDExtractor.defaultWebID)
        XCTAssertEqual(StepfunWebIDExtractor.webID(forToken: "header.@@@not-base64@@@.sig"), StepfunWebIDExtractor.defaultWebID)
    }

    // MARK: - 取数器：凭证解析 + 网络

    private func makeFetcher(
        _ store: FakeStepfunTokenStore,
        environment: [String: String]
    ) -> StepfunLimitsFetcher {
        let client = StepfunWebAPIClient(session: URLProtocolStub.makeSession())
        return StepfunLimitsFetcher(keyStore: store, client: client, environment: environment)
    }

    private func stubBothEndpoints(rateLimit: String, status: String? = nil) {
        URLProtocolStub.handler = { request in
            switch request.url?.lastPathComponent {
            case "QueryStepPlanRateLimit":
                return .init(statusCode: 200, data: Data(rateLimit.utf8))
            case "GetStepPlanStatus":
                return .init(statusCode: 200, data: Data((status ?? "{}").utf8))
            default:
                return .init(statusCode: 404)
            }
        }
    }

    func test_fetch_noToken_returnsNilWithoutRequest() async throws {
        let fetcher = makeFetcher(tokenStore, environment: [:])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "无钥匙串凭证且无环境变量 → 未配置")
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "未配置时零网络请求")
    }

    func test_fetch_environmentToken_parsesWindows() async throws {
        stubBothEndpoints(rateLimit: rollingWindowJSON())
        let fetcher = makeFetcher(tokenStore, environment: ["STEPFUN_TOKEN": "env-token"])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.session]?.usedPercent ?? -1, 40, accuracy: 0.001)
    }

    func test_fetch_keychainToken_takesPriorityOverEnvironment() async throws {
        stubBothEndpoints(rateLimit: rollingWindowJSON())
        tokenStore.storedToken = "keychain-token"
        let fetcher = makeFetcher(tokenStore, environment: ["STEPFUN_TOKEN": "env-token"])
        _ = try await fetcher.fetchLimits(force: false)

        let cookie = URLProtocolStub.recordedRequests.first?.value(forHTTPHeaderField: "Cookie")
        XCTAssertTrue(cookie?.contains("Oasis-Token=keychain-token") == true, "钥匙串凭证优先于环境变量")
        XCTAssertTrue(cookie?.contains("env-token") == false)
        // 请求头须带 oasis-appid / oasis-platform。
        XCTAssertEqual(URLProtocolStub.recordedRequests.first?.value(forHTTPHeaderField: "oasis-appid"), "10300")
        XCTAssertEqual(URLProtocolStub.recordedRequests.first?.value(forHTTPHeaderField: "oasis-platform"), "web")
    }

    func test_fetch_webid_matchesTokenDeviceID() async throws {
        stubBothEndpoints(rateLimit: rollingWindowJSON())
        tokenStore.storedToken = makeJWT(deviceID: "device-xyz")
        let fetcher = makeFetcher(tokenStore, environment: [:])
        _ = try await fetcher.fetchLimits(force: false)

        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "oasis-webid"), "device-xyz")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Cookie")?.contains("Oasis-Webid=device-xyz") == true)
    }

    func test_fetch_unauthorized_throwsReauth() async {
        tokenStore.storedToken = "stale-token"
        URLProtocolStub.stub = .init(statusCode: 401)
        let fetcher = makeFetcher(tokenStore, environment: [:])

        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("401 应抛出 reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_fetch_planStatusFailure_stillReturnsRateLimit() async throws {
        // 限额端点 200、状态端点 500（客户端静默降级）→ 仍产出限额，planLabel 为空。
        let rateLimitBody = rollingWindowJSON()
        URLProtocolStub.handler = { request in
            switch request.url?.lastPathComponent {
            case "QueryStepPlanRateLimit":
                return .init(statusCode: 200, data: Data(rateLimitBody.utf8))
            case "GetStepPlanStatus":
                return .init(statusCode: 500)
            default:
                return .init(statusCode: 404)
            }
        }
        tokenStore.storedToken = "tok"
        let fetcher = makeFetcher(tokenStore, environment: [:])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.session]?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertNil(result?.planLabel)
    }
}
