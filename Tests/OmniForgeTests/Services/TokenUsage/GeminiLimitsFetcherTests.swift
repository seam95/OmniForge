import Foundation
import XCTest
@testable import OmniForge

/// Gemini 限额取数器：retrieveUserQuota 解码（按模型桶 pro/flash/flashLite 分类）、
/// loadCodeAssist tier/project、OAuth 临期自刷新、401/429 语义与失败细分。
final class GeminiLimitsFetcherTests: XCTestCase {
    private var fixedNow: Date!
    private var persistenceCalls: [(bundle: GeminiAuthBundle, tokens: GeminiRefreshedTokens, date: Date)] = []

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

    // MARK: - 解码（按模型桶分类）

    func test_quotaDecoder_mapsModelBucketsToSlots_lowestRemainingWins() {
        let windows = geminiDecoderDecode(buckets: [
            bucketDict(model: "gemini-3-pro", remaining: 0.4, reset: "2026-08-22T10:00:00.000Z"),
            bucketDict(model: "gemini-3-pro-adv", remaining: 0.3, reset: "2026-08-22T10:00:00.000Z"),
            bucketDict(model: "gemini-3-flash", remaining: 0.8, reset: "2026-08-22T09:00:00.000Z"),
            bucketDict(model: "gemini-flash-lite", remaining: 0.2, reset: "2026-08-22T08:00:00.000Z"),
        ])
        XCTAssertEqual(windows[.session]?.usedPercent, 70, "pro 桶取剩余最少者，used = 100 - 30")
        XCTAssertEqual(windows[.weekly]?.usedPercent, 20, "1 - 0.8")
        XCTAssertEqual(windows[.monthly]?.usedPercent, 80, "flash-lite", )
        XCTAssertNil(windows[.credits])
        XCTAssertNil(windows[.session]?.windowSeconds, "Gemini 无窗口秒数 → 不画步速刻度")
        XCTAssertEqual(
            windows[.session]?.resetAt,
            ISO8601DateFormatter().date(from: "2026-08-22T10:00:00Z"),
            "resetTime 附带在最低剩余桶上"
        )
    }

    func test_quotaDecoder_fallbackWhenOnlyUnknownModel() {
        let windows = geminiDecoderDecode(buckets: [
            bucketDict(model: "unique-model", remaining: 0.55, reset: nil),
        ])
        XCTAssertEqual(windows[.session]?.usedPercent, 45, "无 cognate 模型 → 最低剩余全部兜底到会话槽")
        XCTAssertNil(windows[.weekly])
        XCTAssertNil(windows[.monthly])
    }

    func test_quotaDecoder_noBuckets_yieldsEmptyWindows() {
        XCTAssertTrue(geminiDecoderDecode(buckets: []).isEmpty)
    }

    func test_quotaDecoder_handlesNumericStringsAndMidnightReset() {
        let windows = geminiDecoderDecode(buckets: [
            bucketDict(model: "gemini-3-pro", remaining: "0.25", reset: 1_800_100_000, extraField: true),
        ])
        XCTAssertEqual(windows[.session]?.usedPercent, 75, "remainingFraction 字符串数字")
        XCTAssertEqual(windows[.session]?.resetAt, Date(timeIntervalSince1970: 1_800_100_000))
    }

    func test_loadCodeAssistParser_extractsTierAndProject() {
        // cloudaicompanionProject：字符串 / {id} / {projectId} 三种形状。
        XCTAssertEqual(
            GeminiCodeAssistParser.parse(["currentTier": ["id": "standard-tier"], "cloudaicompanionProject": "projects/abc"]).projectID,
            "projects/abc"
        )
        XCTAssertEqual(
            GeminiCodeAssistParser.parse(["currentTier": ["id": "free-tier"], "cloudaicompanionProject": ["id": "proj-id"]]).projectID,
            "proj-id"
        )
        XCTAssertEqual(
            GeminiCodeAssistParser.parse(["cloudaicompanionProject": ["projectId": "proj-pid"]]).projectID,
            "proj-pid"
        )
        let parsed = GeminiCodeAssistParser.parse(["currentTier": ["id": "standard-tier"]])
        XCTAssertEqual(parsed.tier, "standard-tier")
        XCTAssertNil(parsed.projectID)
        XCTAssertNil(GeminiCodeAssistParser.parse(["garbage": true]).tier, "垃圾响应降级不崩")
        XCTAssertEqual(GeminiQuotaPlanLabel.planLabel(fromTier: "standard-tier"), "Paid")
        XCTAssertEqual(GeminiQuotaPlanLabel.planLabel(fromTier: "legacy-tier"), "Legacy")
        XCTAssertEqual(GeminiQuotaPlanLabel.planLabel(fromTier: "free-tier"), "Free")
        XCTAssertNil(GeminiQuotaPlanLabel.planLabel(fromTier: nil))
        XCTAssertNil(GeminiQuotaPlanLabel.planLabel(fromTier: "zzz-tier"))
    }

    // MARK: - 取数编排

    func test_fetchLimits_notConfiguredReturnsNil_andOffline() async throws {
        URLProtocolStub.stub = .init(statusCode: 500)
        let fetcher = makeFetcher(credentials: FakeGeminiCredentials(bundle: nil))
        let result = try await fetcher.fetchLimits()
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "未配置不触网")
    }

    func test_fetchLimits_freshToken_noRefresh_sendsProjectBody() async throws {
        let bundle = makeBundle(accessToken: "fresh", expiry: fixedNow.addingTimeInterval(1800))
        let refresher = FakeGeminiTokenRefresher()
        stubCodeAssistAndQuota()
        let limits = try await makeFetcher(
            credentials: FakeGeminiCredentials(bundle: bundle),
            refresher: refresher
        ).fetchLimits()

        XCTAssertEqual(limits?.provider, .gemini)
        XCTAssertTrue(limits?.configured == true)
        XCTAssertNil(limits?.issue)
        XCTAssertEqual(limits?.confidence, .official)
        XCTAssertEqual(limits?.planLabel, "Paid", "standard-tier → Paid")
        XCTAssertEqual(limits?.subscriptionStatus, .active)
        XCTAssertEqual(limits?.windows[.session]?.usedPercent, 70)
        XCTAssertEqual(limits?.windows[.weekly]?.usedPercent, 20)

        XCTAssertEqual(refresher.callCount, 0, "临期才刷：未过期不刷")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 2, "loadCodeAssist + retrieveUserQuota 两次 POST")
        XCTAssertTrue(URLProtocolStub.recordedRequests[0].url!.path.hasPrefix("/v1internal:loadCodeAssist"))
        XCTAssertTrue(URLProtocolStub.recordedRequests[1].url!.path.hasPrefix("/v1internal:retrieveUserQuota"))
        XCTAssertEqual(URLProtocolStub.recordedBodies[1].jsonObject()?["project"] as? String, "projects/abc", "project 透传")
        XCTAssertEqual(URLProtocolStub.recordedBodies[0].jsonObject().flatMap { $0["metadata"] as? [String: Any] }?["ideType"] as? String, "GEMINI_CLI")
        XCTAssertEqual(URLProtocolStub.recordedRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func test_fetchLimits_staleExpiry_refreshesBeforeQuota_andPersists() async throws {
        let bundle = makeBundle(accessToken: "stale", expiry: fixedNow.addingTimeInterval(-60))
        let refresher = FakeGeminiTokenRefresher()
        stubCodeAssistAndQuota()
        let fetcher = makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle), refresher: refresher)
        _ = try await fetcher.fetchLimits()

        XCTAssertEqual(refresher.callCount, 1, "expiry 已过 → 刷新")
        XCTAssertEqual(refresher.lastRefreshToken, "r-1")
        XCTAssertEqual(persistenceCalls.count, 1, "令牌原子写回")
        XCTAssertEqual(
            URLProtocolStub.recordedRequests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer refreshed-token"
        )
    }

    func test_fetchLimits_refreshRejectedMapsToReauthRequired_andSkipsQuota() async {
        let bundle = makeBundle(accessToken: "stale", expiry: fixedNow.addingTimeInterval(-60))
        let refresher = FakeGeminiTokenRefresher()
        refresher.results = [.failure(GeminiTokenRefreshError.refreshRejected)]
        do {
            _ = try await makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle), refresher: refresher).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired, "刷新 401/403 → 需重新登录 gemini")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 0, "刷新失败短路")
    }

    func test_fetchLimits_refreshNetworkFailure_fallsThroughToExistingToken() async throws {
        let bundle = makeBundle(accessToken: "stale", expiry: fixedNow.addingTimeInterval(-60))
        let refresher = FakeGeminiTokenRefresher()
        refresher.results = [.failure(GeminiTokenRefreshError.network("offline"))]
        stubCodeAssistAndQuota()
        let limits = try await makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle), refresher: refresher).fetchLimits()
        XCTAssertNotNil(limits, "刷新网络失败回退旧 token 继续（best-effort）")
        XCTAssertEqual(URLProtocolStub.recordedRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stale")
    }

    func test_fetchLimits_401ShortCircuitsToReauth() async {
        let bundle = makeBundle(accessToken: "fresh", expiry: fixedNow.addingTimeInterval(1800))
        stubQuotaStatusCode(401)
        do {
            _ = try await makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle)).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchLimits_429CarriesRetryAt() async {
        let bundle = makeBundle(accessToken: "fresh", expiry: fixedNow.addingTimeInterval(1800))
        stubQuotaStatusCode(429, headers: ["retry-after": "240"])
        do {
            _ = try await makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle)).fetchLimits()
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

    func test_fetchLimits_loadCodeAssistFailureDegradesToAnonymousQuota() async throws {
        let bundle = makeBundle(accessToken: "fresh", expiry: fixedNow.addingTimeInterval(1800))
        URLProtocolStub.handler = { request in
            if request.url?.path.hasPrefix("/v1internal:loadCodeAssist") == true {
                return .init(statusCode: 500) // loadCodeAssist 半私有端点故障 → 降级不崩
            }
            return .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
                "buckets": [[
                    "modelId": "gemini-3-pro",
                    "remainingFraction": 0.35,
                    "resetTime": "2026-08-22T10:00:00.000Z",
                ]],
            ]))
        }
        let limits = try await makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle)).fetchLimits()
        XCTAssertNotNil(limits, "loadCodeAssist 失败降级（配额照常取）")
        XCTAssertNil(limits?.planLabel, "tier 缺失 → 无套餐标签")
        XCTAssertTrue(URLProtocolStub.recordedBodies[1].jsonObject()?.isEmpty ?? false, "无 project → 空 body")
    }

    func test_fetchLimits_emptyBucketsMapsToDecoding() async {
        let bundle = makeBundle(accessToken: "fresh", expiry: fixedNow.addingTimeInterval(1800))
        stubQuotaBody(["buckets": []])
        do {
            _ = try await makeFetcher(credentials: FakeGeminiCredentials(bundle: bundle)).fetchLimits()
            XCTFail("expected decoding error")
        } catch let error as LimitError {
            guard case .decoding = error else { XCTFail("unexpected \(error)"); return }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - 工具

    private var recordedBodies: [[String: Any]] {
        URLProtocolStub.recordedBodies.compactMap { data in
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    private func makeFetcher(
        credentials: GeminiCredentialReading,
        refresher: GeminiTokenRefreshing = FakeGeminiTokenRefresher()
    ) -> GeminiLimitsFetcher {
        GeminiLimitsFetcher(
            credentials: credentials,
            refresher: refresher,
            persistence: { bundle, tokens, date in
                self.persistenceCalls.append((bundle, tokens, date))
                var updated = bundle
                updated.accessToken = tokens.accessToken
                updated.idToken = tokens.idToken ?? bundle.idToken
                return updated
            },
            client: ProviderAPIClient(now: { self.fixedNow }, session: URLProtocolStub.makeSession()),
            now: { self.fixedNow }
        )
    }

    private func makeBundle(accessToken: String, expiry: Date) -> GeminiAuthBundle {
        GeminiAuthBundle(
            credsURL: URL(fileURLWithPath: "/tmp/fake/oauth_creds.json"),
            accessToken: accessToken,
            refreshToken: "r-1",
            idToken: nil,
            expiryDate: expiry,
            raw: ["access_token": accessToken]
        )
    }

    private func stubCodeAssistAndQuota() {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasPrefix("/v1internal:loadCodeAssist") == true {
                return .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
                    "currentTier": ["id": "standard-tier"],
                    "cloudaicompanionProject": "projects/abc",
                ]))
            }
            return .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: [
                "buckets": [
                    ["modelId": "gemini-3-pro", "remainingFraction": 0.3, "resetTime": "2026-08-22T10:00:00.000Z"],
                    ["modelId": "gemini-3-flash", "remainingFraction": 0.8, "resetTime": "2026-08-22T09:00:00.000Z"],
                ],
            ]))
        }
    }

    private func stubQuotaStatusCode(_ status: Int, headers: [String: String] = [:]) {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasPrefix("/v1internal:loadCodeAssist") == true {
                return .init(statusCode: 200, data: Data("{}".utf8))
            }
            return .init(statusCode: status, headers: headers)
        }
    }

    private func stubQuotaBody(_ body: [String: Any]) {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasPrefix("/v1internal:loadCodeAssist") == true {
                return .init(statusCode: 200, data: Data("{}".utf8))
            }
            return .init(statusCode: 200, data: try! JSONSerialization.data(withJSONObject: body))
        }
    }

    private func geminiDecoderDecode(buckets: [[String: Any]]) -> [LimitWindowKind: UsageWindow] {
        GeminiQuotaResponseDecoder.decode(buckets: buckets)
    }

    private func bucketDict(
        model: String,
        remaining: Any,
        reset: Any?,
        extraField: Bool = false
    ) -> [String: Any] {
        var dict: [String: Any] = ["modelId": model, "remainingFraction": remaining]
        if let reset { dict["resetTime"] = reset }
        if extraField { dict["satisfiesLimit"] = true }
        return dict
    }
}

private extension Data {
    /// JSON 字典化（测试辅助）。
    func jsonObject() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any]
    }
}
