import XCTest
@testable import OmniForge

final class ClaudeLimitsFetcherTests: XCTestCase {
    private func makeFetcher(
        credentials: ClaudeCredentialReading
    ) -> ClaudeLimitsFetcher {
        ClaudeLimitsFetcher(
            credentials: credentials,
            client: ProviderAPIClient(session: URLProtocolStub.makeSession())
        )
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - 未配置路径（不触网）

    func test_fetchLimits_probeFalseReturnsNotConfigured() async throws {
        let credentials = FakeClaudeCredentials()
        credentials.probeResult = false
        let result = try await makeFetcher(credentials: credentials).fetchLimits()
        XCTAssertNil(result, "未登录 → nil（未配置）")
    }

    func test_fetchLimits_tokenUnreadableFallsBackToNotConfigured() async throws {
        let credentials = FakeClaudeCredentials()
        credentials.tokenResult = .failure(CredentialReadError.keychainUnavailable(-1))
        let result = try await makeFetcher(credentials: credentials).fetchLimits()
        XCTAssertNil(result)
    }

    func test_fetchLimits_invalidPayloadWithEntryPresent_throwsReauth() async throws {
        // Claude Code 登录过期会原地清空 token 而不删条目：reader 对空 token
        // 抛 invalidPayload → 需要重新登录，不是未配置。
        let credentials = FakeClaudeCredentials()
        credentials.tokenResult = .failure(CredentialReadError.invalidPayload)
        do {
            _ = try await makeFetcher(credentials: credentials).fetchLimits()
            XCTFail("expected reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired, "条目在但 token 坏/空 → 重新登录")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "不触网")
    }

    func test_planLabel_storedSubscriptionTypeWinsOverJWT() {
        // 存储原文优先：登录过期 token 被清空时 JWT 解不出，存储原文仍在。
        let stored = ClaudeKeychainCredentialReader.planLabel(
            oauthPayload: ["subscriptionType": "max", "accessToken": ""],
            accessToken: nil
        )
        XCTAssertEqual(stored, "Max")
        // 存储缺失 → JWT claim 兜底。
        let jwtLike = ClaudeKeychainCredentialReader.planLabel(
            oauthPayload: ["accessToken": "jwt"],
            accessToken: Self.jwtWithSubscriptionType("pro")
        )
        XCTAssertEqual(jwtLike, "Pro")
        // 两者皆缺 → nil。
        XCTAssertNil(ClaudeKeychainCredentialReader.planLabel(
            oauthPayload: ["accessToken": "opaque"],
            accessToken: "opaque"
        ))
    }

    /// 构造带 subscriptionType claim 的最小 JWT（header.payload 无签名校验）。
    private static func jwtWithSubscriptionType(_ value: String) -> String {
        func b64(_ json: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: json)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return b64(["alg": "none"])
            + "." + b64(["subscriptionType": value])
            + ".sig"
    }

    // MARK: - 成功路径

    func test_fetchLimits_buildsOfficialSnapshot() async throws {
        let credentials = FakeClaudeCredentials()
        credentials.plan = "Max"
        URLProtocolStub.stub = .init(
            statusCode: 200,
            data: try JSONSerialization.data(withJSONObject: [
                "plan_type": "pro",
                "five_hour": ["used_percent": 82, "limit_window_seconds": 18000],
                "seven_day": ["used_percent": 45, "limit_window_seconds": 604800],
            ])
        )
        let result = try await makeFetcher(credentials: credentials).fetchLimits()
        let limits = try XCTUnwrap(result)
        XCTAssertEqual(limits.provider, .claude)
        XCTAssertTrue(limits.configured)
        XCTAssertEqual(limits.subscriptionStatus, .active)
        XCTAssertEqual(limits.planLabel, "Max")
        XCTAssertEqual(limits.confidence, .official)
        XCTAssertNil(limits.issue)
        XCTAssertEqual(limits.windows[.session]?.usedPercent, 82)
        XCTAssertEqual(limits.windows[.weekly]?.usedPercent, 45)
    }

    // MARK: - 错误路径（已配置但取数失败 → 错误快照，不回退）

    func test_fetchLimits_401ShortCircuitsToReauth() async {
        let credentials = FakeClaudeCredentials()
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await makeFetcher(credentials: credentials).fetchLimits()
            XCTFail("expected reauthRequired throw")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_fetchLimits_429CarriesRetryAt() async {
        let credentials = FakeClaudeCredentials()
        URLProtocolStub.stub = .init(statusCode: 429, headers: ["retry-after": "90"])
        do {
            _ = try await makeFetcher(credentials: credentials).fetchLimits()
            XCTFail("expected rateLimited throw")
        } catch let error as LimitError {
            guard case .rateLimited(let retryAt) = error else {
                XCTFail("expected rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(retryAt.timeIntervalSinceNow, 90, accuracy: 10)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
