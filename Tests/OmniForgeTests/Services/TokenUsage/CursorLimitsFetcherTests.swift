import Foundation
import XCTest
@testable import OmniForge

/// Cursor 限额取数器：usage-summary 解码（totalPercentUsed / Auto-API 车道 / cents 兜底 /
/// 团队池兜底，参考 usage-limits.js normalizeCursorUsageSummary）+ 浏览器伪装头 + 401/429 语义。
final class CursorLimitsFetcherTests: XCTestCase {
    private var fixedNow: Date!

    override func setUp() {
        super.setUp()
        fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeBundle(cookie: String = "WorkosCursorSessionToken=user_abc%3A%3Ajwt-1", userId: String = "user_abc", jwt: String = "jwt-1") -> CursorAuthBundle {
        CursorAuthBundle(jwt: jwt, userId: userId, sessionCookie: cookie)
    }

    private func makeFetcher(
        credentials: CursorCredentialReading = FakeCursorCredentials(bundle: nil),
        client: CursorWebAPIClient? = nil
    ) -> CursorLimitsFetcher {
        CursorLimitsFetcher(
            credentials: credentials,
            client: client ?? CursorWebAPIClient(
                now: { self.fixedNow },
                session: URLProtocolStub.makeSession()
            ),
            now: { self.fixedNow }
        )
    }

    /// usage-summary 车身（参考 normalizeCursorUsageSummary 的字段）。
    private func summaryBody(
        totalPercent: Any? = 82,
        autoPercent: Any? = nil,
        apiPercent: Any? = nil,
        planUsed: Any? = nil,
        planLimit: Any? = nil,
        indUsed: Any? = nil,
        indLimit: Any? = nil,
        teamUsed: Any? = nil,
        teamLimit: Any? = nil,
        membershipType: String? = "pro",
        limitType: String? = "individual"
    ) -> [String: Any] {
        var plan: [String: Any] = [:]
        if let totalPercent { plan["totalPercentUsed"] = totalPercent }
        if let autoPercent { plan["autoPercentUsed"] = autoPercent }
        if let apiPercent { plan["apiPercentUsed"] = apiPercent }
        if let planUsed { plan["used"] = planUsed }
        if let planLimit { plan["limit"] = planLimit }
        var body: [String: Any] = [
            "billingCycleStart": "2026-08-01T00:00:00.000Z",
            "billingCycleEnd": "2026-09-01T00:00:00.000Z",
            "membershipType": membershipType as Any,
            "limitType": limitType as Any,
        ]
        body["individualUsage"] = ["plan": plan, "onDemand": onDemand(used: indUsed, limit: indLimit)]
        body["teamUsage"] = ["onDemand": onDemand(used: teamUsed, limit: teamLimit)]
        return body
    }

    private func onDemand(used: Any?, limit: Any?) -> [String: Any] {
        var d: [String: Any] = [:]
        if let used { d["used"] = used }
        if let limit { d["limit"] = limit }
        return d
    }

    // MARK: - 解码

    func test_summaryDecoder_planTotalPercentIsPrimaryWindow() throws {
        let windows = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: 82))
        let window = try XCTUnwrap(windows[.monthly])
        XCTAssertEqual(window.usedPercent, 82)
        XCTAssertEqual(window.resetAt, try XCTUnwrap(CursorUsageProcessing.parseDate("2026-09-01T00:00:00.000Z")))
        XCTAssertEqual(window.windowSeconds, 31 * 86_400, "计费周期秒数（reset 边界可信）")
    }

    func test_summaryDecoder_fallsBackToAutoApiLanesThenApiThenAuto() throws {
        let avg = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: nil, autoPercent: 60, apiPercent: 40))
        XCTAssertEqual(avg[.monthly]?.usedPercent, 50, "total 缺失 → Auto/API 车道均值")

        let apiOnly = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: nil, autoPercent: nil, apiPercent: 77))
        XCTAssertEqual(apiOnly[.monthly]?.usedPercent, 77, "总缺 → 先 API 车道")

        let autoOnly = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: nil, autoPercent: 66, apiPercent: nil))
        XCTAssertEqual(autoOnly[.monthly]?.usedPercent, 66)
    }

    func test_summaryDecoder_centsFallbackAndOnDemandAndTeamChain() throws {
        // ① plan used/limit cents 反推；② ind onDemand；③ team onDemand 依次兜底。
        let cents = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: nil, planUsed: 40, planLimit: 100))
        XCTAssertEqual(cents[.monthly]?.usedPercent, 40)

        let ind = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: nil, indUsed: 120, indLimit: 200))
        XCTAssertEqual(ind[.monthly]?.usedPercent, 60)

        let team = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: nil, indUsed: nil, indLimit: nil, teamUsed: 30, teamLimit: 300))
        XCTAssertEqual(team[.monthly]?.usedPercent, 10)
    }

    func test_summaryDecoder_synergyZeroPercentPicksPositiveLane() throws {
        // planPercent==0 但 ind/team 有正数 → 实际用正数车道（参考 planPercent===0 修正分支）。
        let ind = CursorUsageSummaryDecoder.decode(summaryBody(totalPercent: 0, indUsed: 50, indLimit: 100))
        XCTAssertEqual(ind[.monthly]?.usedPercent, 50)
    }

    func test_summaryDecoder_enterprisePrefersTeamPool() throws {
        let body = summaryBody(totalPercent: nil, indUsed: nil, indLimit: nil, teamUsed: 80, teamLimit: 100, membershipType: "enterprise")
        XCTAssertEqual(CursorUsageSummaryDecoder.decode(body)[.monthly]?.usedPercent, 80, "enterprise 团队池口径")
        let teamType = summaryBody(totalPercent: nil, indUsed: nil, indLimit: nil, teamUsed: 80, teamLimit: 100, membershipType: "pro", limitType: "team")
        XCTAssertEqual(CursorUsageSummaryDecoder.decode(teamType)[.monthly]?.usedPercent, 80, "limitType=team 团队池口径")
    }

    func test_summaryDecoder_garbageReturnsNoWindows() {
        XCTAssertTrue(CursorUsageSummaryDecoder.decode([:]).isEmpty, "空/变体 body → 无窗口（降级不崩）")
        XCTAssertTrue(CursorUsageSummaryDecoder.decode(["individualUsage": "weird"]).isEmpty)
    }

    func test_summaryDecoder_membershipLabelNormalized() {
        XCTAssertEqual(CursorUsageSummaryDecoder.membershipLabel(summaryBody(membershipType: "pro")), "Pro")
        XCTAssertEqual(CursorUsageSummaryDecoder.membershipLabel(summaryBody(membershipType: "pro_plus")), "Pro Plus")
        XCTAssertNil(CursorUsageSummaryDecoder.membershipLabel(summaryBody(membershipType: "free")), "free 不显示套餐标签")
        XCTAssertNil(CursorUsageSummaryDecoder.membershipLabel(summaryBody(membershipType: nil)))
    }

    // MARK: - Auto / API 车道窗（对齐 B secondary/tertiary）

    func test_laneLabeledWindows_emitsAutoAndApiWithCycleReset() throws {
        let lanes = try XCTUnwrap(
            CursorUsageSummaryDecoder.laneLabeledWindows(summaryBody(totalPercent: 82, autoPercent: 60, apiPercent: 40))
        )
        XCTAssertEqual(lanes.map(\.label), ["Auto", "API"])
        XCTAssertEqual(lanes[0].window.usedPercent, 60)
        XCTAssertEqual(lanes[1].window.usedPercent, 40)
        let end = try XCTUnwrap(CursorUsageProcessing.parseDate("2026-09-01T00:00:00.000Z"))
        for lane in lanes {
            XCTAssertEqual(lane.window.resetAt, end, "车道窗与主窗同 reset")
            XCTAssertEqual(lane.window.windowSeconds, 31 * 86_400, "车道窗与主窗同周期秒数")
        }
    }

    func test_laneLabeledWindows_partialLanesOnlyPresentOnes() throws {
        let autoOnly = try XCTUnwrap(
            CursorUsageSummaryDecoder.laneLabeledWindows(summaryBody(totalPercent: 82, autoPercent: 66))
        )
        XCTAssertEqual(autoOnly.map(\.label), ["Auto"])

        XCTAssertNil(
            CursorUsageSummaryDecoder.laneLabeledWindows(summaryBody(totalPercent: 82)),
            "无车道数据 → nil（不产出空数组）"
        )
    }

    func test_fetchLimits_carriesLaneWindows() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: try! JSONSerialization.data(
            withJSONObject: summaryBody(totalPercent: 75, autoPercent: 30, apiPercent: 12)
        ))
        let fetcher = makeFetcher(credentials: FakeCursorCredentials(bundle: makeBundle()))
        let limits = try await fetcher.fetchLimits()
        XCTAssertEqual(limits?.labeledWindows?.map(\.label), ["Auto", "API"], "fetcher 快照携带车道窗")
        XCTAssertEqual(limits?.labeledWindows?.first?.window.usedPercent, 30)
    }

    // MARK: - 取数编排

    func test_fetchLimits_notConfiguredReturnsNil_andNoNetwork() async throws {
        let fetcher = makeFetcher(credentials: FakeCursorCredentials(bundle: nil))
        let result = try await fetcher.fetchLimits()
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "未配置不触网")
    }

    func test_fetchLimits_successBuildsOfficialMonthlyWindow_andSendsBrowserHeaders() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: summaryBody(totalPercent: 75)))
        let fetcher = makeFetcher(credentials: FakeCursorCredentials(bundle: makeBundle()))
        let limits = try await fetcher.fetchLimits()
        XCTAssertEqual(limits?.provider, .cursor)
        XCTAssertTrue(limits?.configured == true)
        XCTAssertNil(limits?.issue)
        XCTAssertEqual(limits?.confidence, .official)
        XCTAssertEqual(limits?.subscriptionStatus, .active)
        XCTAssertEqual(limits?.planLabel, "Pro")
        XCTAssertEqual(limits?.windows[.monthly]?.usedPercent, 75)

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.url, CursorLimitsFetcher.usageSummaryEndpoint)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "WorkosCursorSessionToken=user_abc%3A%3Ajwt-1",
            "拼装 cookie 原样进请求头"
        )
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla/5.0") ?? false, "伪装浏览器 UA 过 Cloudflare")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.cursor.com/settings")
    }

    func test_fetchLimits_401MapsToReauth() async {
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await makeFetcher(credentials: FakeCursorCredentials(bundle: makeBundle())).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired, "会话过期 → 需在 Cursor 重新登录")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_429CarriesRetryAt() async {
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "240"])
        do {
            _ = try await makeFetcher(credentials: FakeCursorCredentials(bundle: makeBundle())).fetchLimits()
            XCTFail("expected rateLimited")
        } catch let error as LimitError {
            guard case .rateLimited(let retryAt) = error else {
                XCTFail("expected rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(retryAt.timeIntervalSince1970, fixedNow.timeIntervalSince1970 + 240, accuracy: 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_garbageBodyDegradesToConfiguredEmptyWindows() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("cloudflare html".utf8))
        let limits = try await makeFetcher(credentials: FakeCursorCredentials(bundle: makeBundle())).fetchLimits()
        XCTAssertNotNil(limits, "网页 API 改版/被拦截 → 仅降级自身，不崩")
        XCTAssertTrue(limits?.windows.isEmpty ?? false)
        XCTAssertNil(limits?.issue, "解码失败在取数器内兜成空窗口")
    }
}
