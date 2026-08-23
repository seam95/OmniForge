import Foundation
import XCTest
@testable import OmniForge

/// Kimi 限额取数器：coding/v1/usages 解码（usage→周窗 / detail→5h 会话窗 / totalQuota→月窗，
/// 对齐 TokenTracker UI 标注）、expires_at 临期自刷新、401/429 语义与失败细分。
final class KimiLimitsFetcherTests: XCTestCase {
    private var fixedNow: Date!
    private var persistenceCalls: [(bundle: KimiAuthBundle, tokens: KimiRefreshedTokens, date: Date)] = []

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

    // MARK: - 解码（三槽位）

    func test_usageDecoder_mapsUsageToWeeklyWithWindowSeconds() {
        let windows = KimiUsageResponseDecoder.decode([:], usage: usageDict(limit: 4_000_000, used: 1_000_000, reset: "2026-08-22T10:00:00Z"))
        XCTAssertEqual(windows[.weekly]?.usedPercent, 25)
        XCTAssertEqual(windows[.weekly]?.limit, 4_000_000)
        XCTAssertEqual(windows[.weekly]?.used, 1_000_000)
        XCTAssertEqual(windows[.weekly]?.windowSeconds, 7 * 24 * 3600, "usage → 周窗（604800s，pace 可画）")
        XCTAssertEqual(windows[.weekly]?.resetAt, ISO8601DateFormatter().date(from: "2026-08-22T10:00:00Z"))
    }

    func test_usageDecoder_detailAndTotalQuotaFillSessionAndMonthly() {
        let windows = KimiUsageResponseDecoder.decodeFromBody([
            "usage": usageDict(limit: 4_000_000, used: 1_000_000, reset: "2026-08-22T10:00:00Z"),
            "totalQuota": usageDict(limit: 20_000_000, used: 5_000_000, reset: "2026-09-01T00:00:00Z"),
            "limits": [[
                "name": "quota",
                "detail": usageDict(limit: 40_000, used: 10_000, reset: "2026-08-29T08:00:00Z"),
            ]],
        ])
        XCTAssertEqual(windows[.session]?.usedPercent, 25, "limits[0].detail → 会话窗（5h）")
        XCTAssertEqual(windows[.session]?.windowSeconds, 5 * 3600, "detail 窗标注 18000s")
        XCTAssertEqual(windows[.monthly]?.usedPercent, 25, "totalQuota → 月窗")
        XCTAssertEqual(windows[.monthly]?.windowSeconds, nil, "月窗无可信秒数")
        XCTAssertEqual(windows[.weekly]?.usedPercent, 25, "usage → 周窗（三槽位并存）")
    }

    func test_usageDecoder_unboundedLimitOrUnusableWindow_dropped() {
        XCTAssertNil(KimiUsageResponseDecoder.decodeFromBody([:])[.weekly], "无 usage → 不产出")
        XCTAssertNil(KimiUsageResponseDecoder.decodeFromBody([
            "usage": ["limit": 0, "used": 100],
        ])[.weekly], "limit <= 0 丢弃")
        XCTAssertNil(KimiUsageResponseDecoder.decodeFromBody([
            "usage": ["limit": 100, "remaining": "garbage"],
        ])[.weekly], "used 缺失且 remaining 不可解析 → 丢弃")
    }

    func test_usageDecoder_derivesUsedFromRemaining() {
        let windows = KimiUsageResponseDecoder.decodeFromBody([
            "usage": ["limit": 1000, "remaining": 250, "resetTime": 1_800_000_000],
        ])
        XCTAssertEqual(windows[.weekly]?.usedPercent, 75, "used = limit - remaining")
        XCTAssertEqual(windows[.weekly]?.used, 750)
    }

    func test_usageDecoder_resetAtMultiFormat() {
        for reset in ["2027-01-15T08:00:00.000Z", 1_800_000_000, 1_800_000_000_000] {
            let windows = KimiUsageResponseDecoder.decodeFromBody([
                "usage": ["limit": 100, "used": 50, "reset_at": reset],
            ])
            XCTAssertEqual(windows[.weekly]?.resetAt, Date(timeIntervalSince1970: 1_800_000_000), "reset 多格式统一")
        }
    }

    // MARK: - 取数编排

    func test_fetchLimits_notConfiguredReturnsNil_andOffline() async throws {
        URLProtocolStub.stub = .init(statusCode: 500)
        let result = try await makeFetcher(credentials: FakeKimiCredentials(bundle: nil)).fetchLimits()
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "未配置不触网")
    }

    func test_fetchLimits_freshToken_noRefresh_andBuildsOfficialSnapshot() async throws {
        let bundle = makeBundle(accessToken: "fresh", expiresAt: fixedNow.addingTimeInterval(3600))
        let refresher = FakeKimiTokenRefresher()
        stubUsageResponse()
        let limits = try await makeFetcher(
            credentials: FakeKimiCredentials(bundle: bundle),
            refresher: refresher
        ).fetchLimits()

        XCTAssertEqual(limits?.provider, .kimi)
        XCTAssertTrue(limits?.configured == true)
        XCTAssertNil(limits?.issue)
        XCTAssertEqual(limits?.confidence, .official)
        XCTAssertNil(limits?.planLabel, "subType 是额度来源非套餐 → 不显示套餐标签（issue #130 对齐）")
        XCTAssertEqual(limits?.subscriptionStatus, .active)
        XCTAssertEqual(limits?.windows[.weekly]?.usedPercent, 25, "usage → 周窗")
        XCTAssertEqual(limits?.windows[.session]?.usedPercent, 25, "detail → 会话窗")

        XCTAssertEqual(refresher.callCount, 0, "临期才刷：未过期不刷")
        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.url, KimiLimitsFetcher.usageEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func test_fetchLimits_staleExpiresAt_refreshesBeforeUsage_andPersists() async throws {
        let bundle = makeBundle(accessToken: "stale", expiresAt: fixedNow.addingTimeInterval(-60))
        let refresher = FakeKimiTokenRefresher()
        stubUsageResponse()
        let fetcher = makeFetcher(credentials: FakeKimiCredentials(bundle: bundle), refresher: refresher)
        _ = try await fetcher.fetchLimits()

        XCTAssertEqual(refresher.callCount, 1, "expires_at 已过 → 刷新")
        XCTAssertEqual(refresher.lastRefreshToken, "r-1")
        XCTAssertEqual(persistenceCalls.count, 1, "令牌原子写回")
        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
    }

    func test_fetchLimits_refreshRejectedMapsToReauthRequired_andSkipsUsage() async {
        let bundle = makeBundle(accessToken: "stale", expiresAt: fixedNow.addingTimeInterval(-60))
        let refresher = FakeKimiTokenRefresher()
        refresher.results = [.failure(KimiTokenRefreshError.refreshRejected)]
        do {
            _ = try await makeFetcher(credentials: FakeKimiCredentials(bundle: bundle), refresher: refresher).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired, "刷新 401/403 → 需重新登录 kimi")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 0, "刷新失败短路")
    }

    func test_fetchLimits_refreshNetworkFailure_fallsThroughToExistingToken() async throws {
        let bundle = makeBundle(accessToken: "stale", expiresAt: fixedNow.addingTimeInterval(-60))
        let refresher = FakeKimiTokenRefresher()
        refresher.results = [.failure(KimiTokenRefreshError.network("offline"))]
        stubUsageResponse()
        let limits = try await makeFetcher(credentials: FakeKimiCredentials(bundle: bundle), refresher: refresher).fetchLimits()
        XCTAssertNotNil(limits, "刷新网络失败回退旧 token 继续（best-effort）")
        XCTAssertEqual(URLProtocolStub.recordedRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stale")
    }

    func test_fetchLimits_401ShortCircuitsToReauth() async {
        let bundle = makeBundle(accessToken: "fresh", expiresAt: fixedNow.addingTimeInterval(3600))
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await makeFetcher(credentials: FakeKimiCredentials(bundle: bundle)).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_429CarriesRetryAt() async {
        let bundle = makeBundle(accessToken: "fresh", expiresAt: fixedNow.addingTimeInterval(3600))
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "240"])
        do {
            _ = try await makeFetcher(credentials: FakeKimiCredentials(bundle: bundle)).fetchLimits()
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

    func test_fetchLimits_garbageBodyReturnsConfiguredEmptyWindows() async throws {
        let bundle = makeBundle(accessToken: "fresh", expiresAt: fixedNow.addingTimeInterval(3600))
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("garbage".utf8))
        let limits = try await makeFetcher(credentials: FakeKimiCredentials(bundle: bundle)).fetchLimits()
        XCTAssertNotNil(limits, "解析失败降级不崩（无窗口 → 卡片错误行）")
        XCTAssertTrue(limits?.windows.isEmpty ?? false)
    }

    // MARK: - 工具

    private func makeFetcher(
        credentials: KimiCredentialReading,
        refresher: KimiTokenRefreshing = FakeKimiTokenRefresher()
    ) -> KimiLimitsFetcher {
        KimiLimitsFetcher(
            credentials: credentials,
            refresher: refresher,
            persistence: { bundle, tokens, date in
                self.persistenceCalls.append((bundle, tokens, date))
                var updated = bundle
                updated.accessToken = tokens.accessToken
                updated.refreshToken = tokens.refreshToken ?? bundle.refreshToken
                return updated
            },
            client: ProviderAPIClient(now: { self.fixedNow }, session: URLProtocolStub.makeSession()),
            now: { self.fixedNow }
        )
    }

    private func makeBundle(accessToken: String, expiresAt: Date) -> KimiAuthBundle {
        KimiAuthBundle(
            credsURL: URL(fileURLWithPath: "/tmp/fake/credentials/kimi-code.json"),
            accessToken: accessToken,
            refreshToken: "r-1",
            expiresAt: expiresAt,
            scope: "kimi-code",
            tokenType: "Bearer",
            raw: ["access_token": accessToken]
        )
    }

    private func stubUsageResponse() {
        URLProtocolStub.stub = .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
            "user": ["membership": ["level": 1]],
            "subType": "TYPE_PURCHASE",
            "usage": usageDict(limit: 4_000_000, used: 1_000_000, reset: "2026-08-22T10:00:00Z"),
            "parallel": ["limit": 4],
            "limits": [[
                "name": "quota",
                "detail": usageDict(limit: 40_000, used: 10_000, reset: "2026-08-29T08:00:00Z"),
            ]],
        ]))
    }

    private func usageDict(limit: Double, used: Double, reset: Any) -> [String: Any] {
        ["limit": limit, "used": used, "resetTime": reset]
    }
}
