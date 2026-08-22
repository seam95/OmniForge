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
        URLProtocolStub.stub = nil
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
