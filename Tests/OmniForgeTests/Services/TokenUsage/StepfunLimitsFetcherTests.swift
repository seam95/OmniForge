import Foundation
import XCTest
@testable import OmniForge

/// StepFun Step Plan 限额：双模解析（滑动窗口 / Credit 池）、JWT device_id 提取、
/// 钥匙串 + 环境变量凭证解析、401→reauth 映射。
private final class FakeStepfunTokenStore: StepfunTokenStoring {
    var storedToken: String?
    var storedCredentials: StepfunCredentials?
    var readError: Error?
    private(set) var readCount = 0
    private(set) var writeCount = 0

    func readToken() throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return storedToken
    }

    func writeToken(_ token: String) throws {
        writeCount += 1
        storedToken = token
    }
    func deleteToken() throws { storedToken = nil }

    func readCredentials() throws -> StepfunCredentials? { storedCredentials }
    func writeCredentials(_ credentials: StepfunCredentials) throws { storedCredentials = credentials }
    func deleteCredentials() throws { storedCredentials = nil }
}

final class StepfunLimitsFetcherTests: XCTestCase {
    private var tokenStore: FakeStepfunTokenStore!

    override func setUpWithError() throws {
        tokenStore = FakeStepfunTokenStore()
    }

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
        // 清理共享 Cookie 存储，避免 INGRESSCOOKIE 跨用例残留影响「缺少 ingress」用例。
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
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
        let payload = try! JSONSerialization.jsonObject(with: Data(self.rollingWindowJSON().utf8)) as! [String: Any]
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
        let payload = try! JSONSerialization.jsonObject(with: Data(self.rollingWindowJSON().utf8)) as! [String: Any]
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
        return makeJWT(claims: payload)
    }

    private func makeJWT(claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
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
        now: @escaping () -> Date = { Date() }
    ) -> StepfunLimitsFetcher {
        let stub = URLProtocolStub.makeSession()
        let client = StepfunWebAPIClient(session: stub, authSession: stub, now: now)
        return StepfunLimitsFetcher(keyStore: store, client: client, now: now)
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
        let fetcher = makeFetcher(tokenStore)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "无缓存 token 且无凭证 → 未配置")
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "未配置时零网络请求")
    }

    func test_fetch_usesCachedToken_sendsExpectedHeaders() async throws {
        stubBothEndpoints(rateLimit: rollingWindowJSON())
        tokenStore.storedToken = "keychain-token"
        let fetcher = makeFetcher(tokenStore)
        _ = try await fetcher.fetchLimits(force: false)

        let request = URLProtocolStub.recordedRequests.first
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Cookie")?.contains("Oasis-Token=keychain-token") == true, "用钥匙串缓存的 token")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "oasis-appid"), "10300")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "oasis-platform"), "web")
    }

    func test_fetch_webid_matchesTokenDeviceID() async throws {
        stubBothEndpoints(rateLimit: rollingWindowJSON())
        tokenStore.storedToken = makeJWT(deviceID: "device-xyz")
        let fetcher = makeFetcher(tokenStore)
        _ = try await fetcher.fetchLimits(force: false)

        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "oasis-webid"), "device-xyz")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Cookie")?.contains("Oasis-Webid=device-xyz") == true)
    }

    func test_fetch_unauthorized_throwsReauth() async {
        tokenStore.storedToken = "stale-token"
        URLProtocolStub.stub = .init(statusCode: 401)
        let fetcher = makeFetcher(tokenStore)

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
        let fetcher = makeFetcher(tokenStore)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.session]?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertNil(result?.planLabel)
    }

    // MARK: - access 段过期提取

    func test_accessTokenExpiry_readsExpFromFirstJWT() {
        let exp: TimeInterval = 1_800_000_000
        let token = makeJWT(claims: ["exp": exp]) + "..." + makeJWT(claims: ["device_id": "d"])
        XCTAssertEqual(StepfunWebIDExtractor.accessTokenExpiry(token), Date(timeIntervalSince1970: exp))
    }

    func test_accessTokenExpiry_nilForNonJWT() {
        XCTAssertNil(StepfunWebIDExtractor.accessTokenExpiry("not-a-jwt"))
        XCTAssertNil(StepfunWebIDExtractor.accessTokenExpiry(""))
    }

    // MARK: - 登录三步（ingress → register → signin）

    func test_login_threeStep_returnsCombinedToken() async throws {
        URLProtocolStub.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("RegisterDevice") {
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"AT"},"refreshToken":{"raw":"RT"}}"#.utf8))
            } else if url.contains("SignInByPassword") {
                // 校验登录请求体与 Cookie 组装
                let body = String(data: URLProtocolStub.requestBody(request), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("\"username\":\"user\""))
                XCTAssertTrue((request.value(forHTTPHeaderField: "Cookie") ?? "").contains("INGRESSCOOKIE=ing-xyz"))
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"AT2"},"refreshToken":{"raw":"RT2"}}"#.utf8))
            } else {
                return .init(statusCode: 200, headers: ["Set-Cookie": "INGRESSCOOKIE=ing-xyz; Path=/"], data: Data())
            }
        }
        let stub = URLProtocolStub.makeSession()
        let client = StepfunWebAPIClient(session: stub, authSession: stub)
        let token = try await client.login(username: "user", password: "pass")
        XCTAssertEqual(token, "AT2...RT2")

        let urls = URLProtocolStub.recordedRequests.map { $0.url?.absoluteString ?? "" }
        XCTAssertTrue(urls.contains("https://platform.stepfun.com"), "① 首页拿 INGRESSCOOKIE")
        XCTAssertTrue(urls.contains(where: { $0.contains("RegisterDevice") }), "② 设备注册")
        XCTAssertTrue(urls.contains(where: { $0.contains("SignInByPassword") }), "③ 账密登录")
    }

    func test_login_missingIngressCookie_throws() async {
        URLProtocolStub.handler = { _ in .init(statusCode: 200, data: Data()) }
        let stub = URLProtocolStub.makeSession()
        let client = StepfunWebAPIClient(session: stub, authSession: stub)
        do {
            _ = try await client.login(username: "u", password: "p")
            XCTFail("拿不到 INGRESSCOOKIE 应抛错")
        } catch {
            // expected
        }
    }

    func test_refreshToken_returnsCombinedToken() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertTrue((request.url?.absoluteString ?? "").contains("RefreshToken"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Oasis-Token"), "old...pair")
            return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"NEWAT"},"refreshToken":{"raw":"NEWRT"}}"#.utf8))
        }
        let stub = URLProtocolStub.makeSession()
        let client = StepfunWebAPIClient(session: stub, authSession: stub)
        let token = try await client.refreshToken(token: "old...pair")
        XCTAssertEqual(token, "NEWAT...NEWRT")
    }

    // MARK: - 续期编排

    func test_fetch_proactiveRefresh_whenAccessNearExpiry() async throws {
        let now = Date()
        tokenStore.storedToken = makeJWT(claims: ["exp": Int(now.timeIntervalSince1970) + 100]) // < 300s 窗口
        URLProtocolStub.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("RefreshToken") {
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"FRESH"},"refreshToken":{"raw":"FRESHRT"}}"#.utf8))
            } else if url.contains("QueryStepPlanRateLimit") {
                return .init(statusCode: 200, data: Data(self.rollingWindowJSON().utf8))
            }
            return .init(statusCode: 200, data: Data("{}".utf8))
        }
        let fetcher = makeFetcher(tokenStore, now: { now })
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.contains { ($0.url?.absoluteString ?? "").contains("RefreshToken") }, "临近过期先刷新")
        XCTAssertEqual(tokenStore.storedToken, "FRESH...FRESHRT", "新 token 落库")
        XCTAssertTrue(URLProtocolStub.recordedRequests.contains { ($0.value(forHTTPHeaderField: "Cookie") ?? "").contains("Oasis-Token=FRESH") }, "用新 token 查询")
    }

    func test_fetch_on401_refreshesAndRetries() async throws {
        let now = Date()
        tokenStore.storedToken = makeJWT(claims: ["exp": Int(now.timeIntervalSince1970) + 100_000]) // 远离过期，不主动刷新
        final class Counter { var rate = 0 }
        let counter = Counter()
        URLProtocolStub.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("RefreshToken") {
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"R2"},"refreshToken":{"raw":"R2RT"}}"#.utf8))
            } else if url.contains("QueryStepPlanRateLimit") {
                counter.rate += 1
                if counter.rate == 1 { return .init(statusCode: 401) }
                return .init(statusCode: 200, data: Data(self.rollingWindowJSON().utf8))
            }
            return .init(statusCode: 200, data: Data("{}".utf8))
        }
        let fetcher = makeFetcher(tokenStore, now: { now })
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(counter.rate, 2, "401 后刷新并重试一次")
        XCTAssertEqual(tokenStore.storedToken, "R2...R2RT", "刷新后的新 token 落库")
    }

    func test_fetch_refreshFails_reloginWithCredentials() async throws {
        let now = Date()
        tokenStore.storedToken = makeJWT(claims: ["exp": Int(now.timeIntervalSince1970) + 100_000])
        tokenStore.storedCredentials = StepfunCredentials(username: "u", password: "p")
        final class Flags { var loggedIn = false }
        let flags = Flags()
        URLProtocolStub.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://platform.stepfun.com" {
                return .init(statusCode: 200, headers: ["Set-Cookie": "INGRESSCOOKIE=ing; Path=/"], data: Data())
            } else if url.contains("RegisterDevice") {
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"ANON"},"refreshToken":{"raw":"ANONRT"}}"#.utf8))
            } else if url.contains("SignInByPassword") {
                flags.loggedIn = true
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"LIVE"},"refreshToken":{"raw":"LIVERT"}}"#.utf8))
            } else if url.contains("RefreshToken") {
                return .init(statusCode: 401) // 续期失败（设备段失效）
            } else if url.contains("QueryStepPlanRateLimit") {
                return flags.loggedIn
                    ? .init(statusCode: 200, data: Data(self.rollingWindowJSON().utf8))
                    : .init(statusCode: 401)
            }
            return .init(statusCode: 200, data: Data("{}".utf8))
        }
        let fetcher = makeFetcher(tokenStore, now: { now })
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertTrue(flags.loggedIn, "续期失败 → 凭证重登")
        XCTAssertEqual(tokenStore.storedToken, "LIVE...LIVERT")
    }

    func test_fetch_credentialsLogin_whenNoToken() async throws {
        tokenStore.storedToken = nil
        tokenStore.storedCredentials = StepfunCredentials(username: "u", password: "p")
        URLProtocolStub.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url == "https://platform.stepfun.com" {
                return .init(statusCode: 200, headers: ["Set-Cookie": "INGRESSCOOKIE=ing; Path=/"], data: Data())
            } else if url.contains("RegisterDevice") {
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"A"},"refreshToken":{"raw":"R"}}"#.utf8))
            } else if url.contains("SignInByPassword") {
                return .init(statusCode: 200, data: Data(#"{"accessToken":{"raw":"A2"},"refreshToken":{"raw":"R2"}}"#.utf8))
            } else if url.contains("QueryStepPlanRateLimit") {
                return .init(statusCode: 200, data: Data(self.rollingWindowJSON().utf8))
            }
            return .init(statusCode: 200, data: Data("{}".utf8))
        }
        let fetcher = makeFetcher(tokenStore)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(tokenStore.storedToken, "A2...R2", "无 token 时凭证登录并落库")
    }

    func test_fakeStore_credentialRoundTrip() throws {
        XCTAssertNil(try tokenStore.readCredentials())
        try tokenStore.writeCredentials(StepfunCredentials(username: "u", password: "p"))
        XCTAssertEqual(try tokenStore.readCredentials(), StepfunCredentials(username: "u", password: "p"))
        try tokenStore.deleteCredentials()
        XCTAssertNil(try tokenStore.readCredentials())
    }
}
