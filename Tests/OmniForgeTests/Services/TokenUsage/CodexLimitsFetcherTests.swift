import Foundation
import XCTest
@testable import OmniForge

/// Codex wham 限额解码 + 取数器：JWT 临期自刷新、失败细分、401/429 语义与 Claude 一致。
final class CodexLimitsFetcherTests: XCTestCase {
    private var fixedNow: Date!
    private var persistenceCalls: [(bundle: CodexAuthBundle, tokens: CodexRefreshedTokens, date: Date)] = []

    override func setUp() {
        super.setUp()
        fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        persistenceCalls = []
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - 取数编排

    func test_fetchLimits_notConfiguredReturnsNil() async throws {
        let fetcher = makeFetcher(credentials: FakeCodexCredentials(bundle: nil))
        let result = try await fetcher.fetchLimits()
        XCTAssertNil(result, "无 auth.json → 未配置")
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "未配置不触网")
    }

    func test_fetchLimits_freshTokenSkipsRefresh_andBuildsOfficialSnapshot() async throws {
        let token = freshToken
        let bundle = makeBundle(accessToken: token, refreshToken: "r-1", now: fixedNow)
        let refresher = FakeCodexTokenRefresher()
        let fetcher = makeFetcher(
            credentials: FakeCodexCredentials(bundle: bundle),
            refresher: refresher
        )
        stubWhamResponses()
        let result = try await fetcher.fetchLimits(force: false)

        let limits = try XCTUnwrap(result)
        XCTAssertEqual(limits.provider, .codex)
        XCTAssertTrue(limits.configured)
        XCTAssertNil(limits.issue)
        XCTAssertEqual(limits.confidence, .official)
        XCTAssertFalse(limits.stale)
        XCTAssertEqual(limits.subscriptionStatus, .active, "JWT 有可显示套餐 → 已激活")
        XCTAssertEqual(limits.planLabel, "Plus")
        XCTAssertEqual(limits.windows[.session]?.usedPercent, 82)
        XCTAssertEqual(limits.windows[.session]?.windowSeconds, 18000)
        XCTAssertEqual(limits.windows[.weekly]?.usedPercent, 45)
        XCTAssertEqual(limits.windows[.credits]?.used, 200)
        XCTAssertEqual(limits.windows[.credits]?.remaining, 800)

        XCTAssertEqual(refresher.callCount, 0, "临期才刷：远未过期不调刷新")

        let usageRequest = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(usageRequest.url, CodexLimitsFetcher.usageEndpoint)
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(usageRequest.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "无 account_id 时不带该头")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "wham + 兄弟 reset-credits 两次串行")
    }

    func test_fetchLimits_staleJwtRefreshesBeforeWham_andPersists() async throws {
        let staleToken = staleAccessToken()
        let bundle = makeBundle(accessToken: staleToken, refreshToken: "r-1", now: fixedNow)
        let refresher = FakeCodexTokenRefresher()
        let fetcher = makeFetcher(
            credentials: FakeCodexCredentials(bundle: bundle),
            refresher: refresher
        )
        stubWhamResponses()

        let limits = try await fetcher.fetchLimits()
        XCTAssertNotNil(limits)

        XCTAssertEqual(refresher.callCount, 1, "临期（≤5 分钟）触发刷新")
        XCTAssertEqual(refresher.lastRefreshToken, "r-1")
        let usageRequest = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token", "wham 用刷新后的 access token")
        XCTAssertEqual(persistenceCalls.count, 1, "新令牌原子写回 auth.json")
        XCTAssertEqual(persistenceCalls.last?.tokens.accessToken, "refreshed-token")
    }

    func test_fetchLimits_refreshRejectedMapsToReauthRequired_andSkipsWham() async {
        let staleToken = staleAccessToken()
        let bundle = makeBundle(accessToken: staleToken, refreshToken: "r-1", now: fixedNow)
        let refresher = FakeCodexTokenRefresher()
        refresher.results = [.failure(CodexTokenRefreshError.refreshTokenExpired)]
        let fetcher = makeFetcher(
            credentials: FakeCodexCredentials(bundle: bundle),
            refresher: refresher
        )
        do {
            _ = try await fetcher.fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired, "refresh_token_expired/reused/invalidated → codex login")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 0, "刷新失败短路：不再打 wham")
    }

    func test_fetchLimits_refreshNetworkFailure_fallsThroughToExistingToken() async throws {
        let staleToken = staleAccessToken()
        let bundle = makeBundle(accessToken: staleToken, refreshToken: "r-1", now: fixedNow)
        let refresher = FakeCodexTokenRefresher()
        refresher.results = [.failure(CodexTokenRefreshError.network("offline"))]
        let fetcher = makeFetcher(
            credentials: FakeCodexCredentials(bundle: bundle),
            refresher: refresher
        )
        stubWhamResponses()
        let limits = try await fetcher.fetchLimits()
        XCTAssertNotNil(limits, "刷新网络失败回退旧 token 继续（best-effort）")
        let usageRequest = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(usageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(staleToken)")
    }

    func test_fetchLimits_accountIdHeaderIncludedWhenKnown() async throws {
        let bundle = makeBundle(accessToken: "fresh-token", refreshToken: nil, now: fixedNow, accountID: "acct-77")
        let fetcher = makeFetcher(credentials: FakeCodexCredentials(bundle: bundle))
        stubWhamResponses()
        _ = try await fetcher.fetchLimits()
        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-77", "免费/多账号需显式 account id（对齐 CodexBar）")
    }

    func test_fetchLimits_401ShortCircuitsToReauth() async {
        let bundle = makeBundle(accessToken: "fresh-token", refreshToken: nil, now: fixedNow)
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await makeFetcher(credentials: FakeCodexCredentials(bundle: bundle)).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_429CarriesRetryAt() async {
        let bundle = makeBundle(accessToken: "fresh-token", refreshToken: nil, now: fixedNow)
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "240"])
        do {
            _ = try await makeFetcher(credentials: FakeCodexCredentials(bundle: bundle)).fetchLimits()
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

    // MARK: - wham 响应解码

    func test_whamDecoder_classifiesWindowsBySeconds_notPosition() {
        let object: [String: Any] = [
            "rate_limit": [
                // 免费账号可能把周窗塞进 primary 槽位 → 按秒数分类而非按位置。
                "primary_window": ["used_percent": 45, "limit_window_seconds": 604800],
                "secondary_window": ["used_percent": 82, "limit_window_seconds": 18000],
            ],
        ]
        let windows = CodexWhamResponseDecoder.decode(object)
        XCTAssertEqual(windows[.weekly]?.usedPercent, 45)
        XCTAssertEqual(windows[.session]?.usedPercent, 82)
    }

    func test_whamDecoder_positionalFallbackWhenSecondsMissing() {
        let object: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 82],
                "secondary_window": ["used_percent": 45],
            ],
        ]
        let windows = CodexWhamResponseDecoder.decode(object)
        XCTAssertEqual(windows[.session]?.usedPercent, 82, "无秒数 → 位置兜底 primary=会话")
        XCTAssertEqual(windows[.weekly]?.usedPercent, 45)
    }

    func test_whamDecoder_dropsWindowWithoutUsablePercent() {
        let object: [String: Any] = [
            "rate_limit": [
                "primary_window": ["limit_window_seconds": 18000],
                "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800],
            ],
        ]
        let windows = CodexWhamResponseDecoder.decode(object)
        XCTAssertNil(windows[.session], "无 used_percent 且无 limit/used → 不渲染为 0%")
        XCTAssertEqual(windows[.weekly]?.usedPercent, 45)
    }

    func test_whamDecoder_sparkAdditionalRateLimitsFillMissingWindow() {
        let object: [String: Any] = [
            "additional_rate_limits": [
                [
                    "limit_name": "spark",
                    "metered_feature": "spark",
                    "rate_limit": [
                        "primary_window": ["used_percent": 88, "limit_window_seconds": 18000],
                    ],
                ],
            ],
        ]
        let windows = CodexWhamResponseDecoder.decode(object)
        XCTAssertEqual(windows[.session]?.usedPercent, 88, "无主 rate_limit 时 spark 补齐会话窗")
        XCTAssertNil(windows[.weekly])
    }

    func test_whamDecoder_creditsWindow_carriesLimitUsedRemaining() {
        let object: [String: Any] = [
            "spend_control": [
                "individual_limit": [
                    "limit": 1000, "used": 200, "remaining": 800,
                    "used_percent": 20, "reset_at": 1_800_100_000, "source": "gpt4o",
                ],
            ],
        ]
        let windows = CodexWhamResponseDecoder.decode(object)
        let credits = windows[.credits]
        XCTAssertEqual(credits?.usedPercent, 20)
        XCTAssertEqual(credits?.limit, 1000)
        XCTAssertEqual(credits?.used, 200)
        XCTAssertEqual(credits?.remaining, 800)
        XCTAssertEqual(credits?.unit, "credits")
        XCTAssertEqual(try XCTUnwrap(credits?.resetAt).timeIntervalSince1970, 1_800_100_000, accuracy: 1)
    }

    func test_whamDecoder_creditsWindow_derivesPercentFromRatio() {
        let object: [String: Any] = [
            "spend_control": ["individual_limit": ["limit": 500, "used": 375]],
        ]
        let credits = CodexWhamResponseDecoder.decode(object)[.credits]
        XCTAssertEqual(credits?.usedPercent, 75, "limit/used 反推百分比")
    }

    func test_whamDecoder_resetCredits_parsesCountsAndEarliest() throws {
        let resetCredits = CodexWhamResponseDecoder.decodeResetCredits([
            "available_count": 0,
            "total_earned_count": 2,
            "credits": [
                ["status": "available", "expires_at": "2027-08-22T10:00:00.000Z", "reset_type": "codex_rate_limits"],
                ["status": "available", "expires_at": "2027-08-22T12:00:00.000Z"],
                ["status": "used", "expires_at": "2027-08-22T09:00:00.000Z"],
            ],
        ], now: fixedNow)
        XCTAssertEqual(resetCredits?.availableCount, 0)
        XCTAssertEqual(resetCredits?.totalEarnedCount, 2)
        let earliest = try XCTUnwrap(resetCredits?.earliestExpiresAt)
        XCTAssertEqual(ISO8601DateFormatter().string(from: earliest), "2027-08-22T10:00:00Z", "仅 available 且未过期的 credits 参与")
        XCTAssertNil(CodexWhamResponseDecoder.decodeResetCredits("garbage"))
        XCTAssertNil(CodexWhamResponseDecoder.decodeResetCredits(["available_count": -1]))
    }

    func test_fetchLimits_prefersSiblingResetCredits_andEnrichesCreditWindowReset() async throws {
        let bundle = makeBundle(accessToken: "fresh-token", refreshToken: nil, now: fixedNow)
        let fetcher = makeFetcher(credentials: FakeCodexCredentials(bundle: bundle))
        // 主端点：credits 窗口不给 reset_at；体内 reset credits 可用数 1。
        // 兄弟端点：返回更新后的 reset credits（可用数 3）。
        URLProtocolStub.handler = { request in
            if request.url == CodexLimitsFetcher.resetCreditsEndpoint {
                return .init(statusCode: 200, data: Data("""
                {"available_count":3,"total_earned_count":5,"credits":[
                  {"status":"available","expires_at":"2027-08-22T09:45:00.000Z","reset_type":"codex_rate_limits"}]}
                """.utf8))
            }
            return .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
                "spend_control": ["individual_limit": ["limit": 1000, "used": 200, "remaining": 800]],
                "rate_limit_reset_credits": ["available_count": 1],
            ]))
        }
        let limits = try await fetcher.fetchLimits()
        let credits = try XCTUnwrap(limits?.windows[.credits])
        XCTAssertEqual(credits.resetAt?.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2027-08-22T09:45:00Z")?.timeIntervalSince1970,
                       "credits 缺 reset_at 时用兄弟端点最早 expires_at 补 reset")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "先主端点再兄弟端点（串行）")
    }

    func test_fetchLimits_siblingFailureDegradesToInBodyResetCredits() async throws {
        let bundle = makeBundle(accessToken: "fresh-token", refreshToken: nil, now: fixedNow)
        let fetcher = makeFetcher(credentials: FakeCodexCredentials(bundle: bundle))
        URLProtocolStub.handler = { request in
            if request.url == CodexLimitsFetcher.resetCreditsEndpoint {
                return .init(statusCode: 0, error: URLError(.timedOut))
            }
            return .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
                "rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": 18000]],
                "rate_limit_reset_credits": ["available_count": 2],
            ]))
        }
        let limits = try await fetcher.fetchLimits()
        XCTAssertNotNil(limits, "兄弟端点失败降级不崩")
        XCTAssertEqual(limits?.windows[.session]?.usedPercent, 10)
    }

    // MARK: - 工具

    private func makeFetcher(
        credentials: CodexCredentialReading,
        refresher: CodexTokenRefreshing = FakeCodexTokenRefresher()
    ) -> CodexLimitsFetcher {
        CodexLimitsFetcher(
            credentials: credentials,
            refresher: refresher,
            persistence: { bundle, tokens, date in
                self.persistenceCalls.append((bundle, tokens, date))
                var updated = bundle
                updated.accessToken = tokens.accessToken
                updated.refreshToken = tokens.refreshToken ?? bundle.refreshToken
                updated.idToken = tokens.idToken ?? bundle.idToken
                return updated
            },
            client: ProviderAPIClient(now: { self.fixedNow }, session: URLProtocolStub.makeSession()),
            resetCreditsClient: ProviderAPIClient(
                timeout: CodexLimitsFetcher.resetCreditsTimeout,
                now: { self.fixedNow },
                session: URLProtocolStub.makeSession()
            ),
            now: { self.fixedNow }
        )
    }

    private func stubWhamResponses() {
        URLProtocolStub.handler = { _ in
            .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
                "rate_limit": [
                    "primary_window": ["used_percent": 82, "limit_window_seconds": 18000],
                    "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800],
                ],
                "spend_control": [
                    "individual_limit": [
                        "limit": 1000, "used": 200, "remaining": 800, "used_percent": 20,
                        "reset_at": 1_800_100_000,
                    ],
                ],
                "rate_limit_reset_credits": ["available_count": 100],
            ]))
        }
    }

    private func makeBundle(
        accessToken: String,
        refreshToken: String?,
        now: Date,
        accountID: String? = nil
    ) -> CodexAuthBundle {
        CodexAuthBundle(
            authURL: URL(fileURLWithPath: "/tmp/fake/auth.json"),
            accessToken: accessToken,
            idToken: nil,
            refreshToken: refreshToken,
            accountID: accountID,
            planType: nil,
            lastRefresh: "2026-08-20T00:00:00.000Z",
            raw: ["tokens": ["access_token": accessToken]]
        )
    }

    /// fresh JWT：exp = now + 1 小时（顶层标准声明），带 Plus 套餐声明（命名空间）。
    private var freshToken: String {
        jwtForAccess(exp: Int(fixedNow.timeIntervalSince1970) + 3600, plan: "plus")
    }

    /// 临期 JWT：exp = now + 1 分钟。
    private func staleAccessToken() -> String {
        jwtForAccess(exp: Int(fixedNow.timeIntervalSince1970) + 60, plan: nil)
    }

    /// 标准 JWT：`exp` 在 payload 顶层（真实 Codex access token 结构），套餐在 auth 命名空间。
    private func jwtForAccess(exp: Int, plan: String?) -> String {
        var payload: [String: Any] = ["exp": exp]
        if let plan {
            payload[CodexPlanExtractor.authNamespace] = ["chatgpt_plan_type": plan]
        }
        return makeJWT(payload: payload)
    }

    private func makeJWT(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let base64url = { (data: Data) -> String in
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64url(header)).\(base64url(payloadData)).sig"
    }
}
