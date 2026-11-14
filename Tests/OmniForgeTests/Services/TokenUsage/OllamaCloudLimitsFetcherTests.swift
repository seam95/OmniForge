import Foundation
import XCTest
@testable import OmniForge

// MARK: - 测试替身

private final class FakeOllamaCloudAPIKeyStore: OllamaCloudAPIKeyStoring {
    var storedKey: String?
    func hasAPIKey() -> Bool { storedKey?.isEmpty == false }
    func readAPIKey() throws -> String? { storedKey }
    func writeAPIKey(_ apiKey: String) throws { storedKey = apiKey }
    func deleteAPIKey() throws { storedKey = nil }
}

private final class FakeOllamaCloudBalanceClient: OllamaCloudBalanceFetching {
    var payload: [String: Any]?
    var error: Error?
    private(set) var recordedURLs: [URL] = []
    private(set) var recordedHeaders: [[String: String]] = []

    func getJSON(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        recordedURLs.append(url)
        recordedHeaders.append(headers)
        if let error { throw error }
        return payload ?? [:]
    }
}

// MARK: - 解析纯函数

/// Ollama Cloud balance 解析：新版美元总池 / 旧版百分比配额 / 社区变体 / 宽松数值。
final class OllamaCloudBalanceParsingTests: XCTestCase {

    // MARK: 形态 A（新版美元余额）

    func test_modernShape_withPurchased_mergesTotalPool() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "included": [
                "balance_usd": 8.5,
                "allowance_usd": 20.0,
                "period": ["from": 1_790_000_000, "until": 1_791_000_000],
            ],
            "purchased": ["balance_usd": 5.0],
        ])
        let credits = try XCTUnwrap(limits?.windows[.credits])
        // 总池口径：limit = 20 + 5，remaining = 8.5 + 5，used = 11.5 → 46%。
        XCTAssertEqual(credits.limit, 25.0)
        XCTAssertEqual(credits.remaining, 13.5)
        XCTAssertEqual(credits.used, 11.5)
        XCTAssertEqual(credits.usedPercent, 46.0, accuracy: 0.001)
        XCTAssertEqual(credits.unit, "USD")
        XCTAssertEqual(credits.resetAt?.timeIntervalSince1970, 1_791_000_000)
    }

    func test_modernShape_withoutPurchased() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "included": ["balance_usd": 8.5, "allowance_usd": 20.0],
        ])
        let credits = try XCTUnwrap(limits?.windows[.credits])
        XCTAssertEqual(credits.limit, 20.0)
        XCTAssertEqual(credits.remaining, 8.5)
        XCTAssertEqual(credits.used, 11.5)
        XCTAssertNil(credits.resetAt)
    }

    func test_modernShape_stringNumbersAccepted() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "included": ["balance_usd": "8.5", "allowance_usd": "20"],
        ])
        let credits = try XCTUnwrap(limits?.windows[.credits])
        XCTAssertEqual(credits.remaining, 8.5)
        XCTAssertEqual(credits.limit, 20.0)
    }

    func test_purchasedOnly_creditsWindowWithoutLimit() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "purchased": ["balance_usd": 5.0],
        ])
        let credits = try XCTUnwrap(limits?.windows[.credits])
        XCTAssertEqual(credits.remaining, 5.0)
        XCTAssertNil(credits.limit)
        XCTAssertNil(credits.used)
        XCTAssertEqual(credits.usedPercent, 0)
        XCTAssertEqual(credits.unit, "USD")
        XCTAssertEqual(limits?.windows.count, 1)
    }

    // MARK: 形态 B（旧版百分比配额）

    func test_legacyShape_sessionAndWeeklyWindows() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "included": [
                "session": ["remaining_percent": 80, "resets_at": 1_791_000_000],
                "weekly": ["remaining_percent": 45, "resets_at": 1_791_500_000],
            ],
        ])
        let windows = try XCTUnwrap(limits?.windows)
        XCTAssertEqual(windows.count, 2)
        XCTAssertNotNil(windows[.session])
        XCTAssertNotNil(windows[.weekly])
        let session = try XCTUnwrap(limits?.windows[.session])
        XCTAssertEqual(session.usedPercent, 20.0)
        XCTAssertEqual(session.resetAt?.timeIntervalSince1970, 1_791_000_000)
        let weekly = try XCTUnwrap(limits?.windows[.weekly])
        XCTAssertEqual(weekly.usedPercent, 55.0)
    }

    func test_legacyShape_clampsOutOfRangePercent() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "included": ["session": ["remaining_percent": 120]],
        ])
        // 120% 剩余 → clamp 100 → 已用 0%。
        XCTAssertEqual(limits?.windows[.session]?.usedPercent, 0)
    }

    // MARK: 社区变体

    func test_communityWindowsMonthlyVariant() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "windows": ["monthly": ["used_pct": 63.5, "reset_at": 1_791_200_000]],
        ])
        let monthly = try XCTUnwrap(limits?.windows[.monthly])
        XCTAssertEqual(monthly.usedPercent, 63.5)
        XCTAssertEqual(monthly.resetAt?.timeIntervalSince1970, 1_791_200_000)
    }

    func test_communitySpentUSDFillsCreditsUsed() throws {
        let limits = OllamaCloudBalanceParsing.parse([
            "included": ["balance_usd": 8.5],
            "credits": ["included": ["spent_usd": 11.5]],
        ])
        let credits = try XCTUnwrap(limits?.windows[.credits])
        XCTAssertEqual(credits.used, 11.5)
    }

    // MARK: 降级

    func test_emptyPayload_returnsNil() {
        XCTAssertNil(OllamaCloudBalanceParsing.parse([:]))
        XCTAssertNil(OllamaCloudBalanceParsing.parse(["included": [:]]))
        XCTAssertNil(OllamaCloudBalanceParsing.parse(["unrelated": "field"]))
    }
}

// MARK: - Fetcher

/// Ollama Cloud fetcher：Key 守卫、Key 优先级、Bearer 头、错误映射、快照组装。
final class OllamaCloudLimitsFetcherTests: XCTestCase {

    private func makeFetcher(
        keychainKey: String? = nil,
        envKey: String? = nil,
        client: FakeOllamaCloudBalanceClient = FakeOllamaCloudBalanceClient()
    ) -> (OllamaCloudLimitsFetcher, FakeOllamaCloudBalanceClient) {
        let keyStore = FakeOllamaCloudAPIKeyStore()
        keyStore.storedKey = keychainKey
        var environment: [String: String] = [:]
        if let envKey { environment[OllamaCloudLimitsFetcher.environmentKeyName] = envKey }
        let fetcher = OllamaCloudLimitsFetcher(
            keyStore: keyStore,
            client: client,
            environment: environment
        )
        return (fetcher, client)
    }

    func test_noApiKey_returnsNilWithoutNetwork() async throws {
        let (fetcher, client) = makeFetcher()
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(client.recordedURLs.isEmpty, "无 key 零网络请求")
    }

    func test_keychainKeyPreferredOverEnvKey() async throws {
        let client = FakeOllamaCloudBalanceClient()
        client.payload = ["included": ["balance_usd": 1.0, "allowance_usd": 2.0]]
        let (fetcher, clientRef) = makeFetcher(keychainKey: " keychain-key ", envKey: "env-key", client: client)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(clientRef.recordedHeaders.first?["Authorization"], "Bearer keychain-key", "钥匙串 key 优先且去首尾空白")
    }

    func test_envKeyFallbackWhenKeychainEmpty() async throws {
        let client = FakeOllamaCloudBalanceClient()
        client.payload = ["included": ["balance_usd": 1.0, "allowance_usd": 2.0]]
        let (fetcher, clientRef) = makeFetcher(envKey: "env-key", client: client)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(clientRef.recordedHeaders.first?["Authorization"], "Bearer env-key")
    }

    func test_successBuildsOfficialSnapshot() async throws {
        let client = FakeOllamaCloudBalanceClient()
        client.payload = [
            "included": ["balance_usd": 8.5, "allowance_usd": 20.0],
            "purchased": ["balance_usd": 5.0],
        ]
        let (fetcher, _) = makeFetcher(keychainKey: "k", client: client)
        let fetched = try await fetcher.fetchLimits(force: false)
        let result = try XCTUnwrap(fetched)
        XCTAssertEqual(result.provider, .ollamaCloud)
        XCTAssertTrue(result.configured)
        XCTAssertEqual(result.subscriptionStatus, .active)
        XCTAssertEqual(result.confidence, .official)
        XCTAssertNil(result.issue)
        XCTAssertFalse(result.stale)
        XCTAssertEqual(result.windows[.credits]?.remaining, 13.5)
    }

    func test_endpointAndAcceptHeader() async throws {
        let client = FakeOllamaCloudBalanceClient()
        client.payload = ["included": ["balance_usd": 1.0]]
        let (fetcher, clientRef) = makeFetcher(keychainKey: "k", client: client)
        _ = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(clientRef.recordedURLs.first, OllamaCloudLimitsFetcher.balanceURL)
        XCTAssertEqual(clientRef.recordedHeaders.first?["Accept"], "application/json")
    }

    func test_unparseablePayload_returnsNil() async throws {
        let client = FakeOllamaCloudBalanceClient()
        client.payload = [:]
        let (fetcher, _) = makeFetcher(keychainKey: "k", client: client)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "解析不出窗口降级为未配置口径")
    }

    func test_reauthErrorPropagates() async {
        let client = FakeOllamaCloudBalanceClient()
        client.error = LimitError.reauthRequired
        let (fetcher, _) = makeFetcher(keychainKey: "k", client: client)
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("应抛 reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func test_rateLimitedErrorPropagates() async {
        let retryAt = Date(timeIntervalSince1970: 1_791_000_000)
        let client = FakeOllamaCloudBalanceClient()
        client.error = LimitError.rateLimited(retryAt: retryAt)
        let (fetcher, _) = makeFetcher(keychainKey: "k", client: client)
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("应抛 rateLimited")
        } catch let error as LimitError {
            XCTAssertEqual(error, .rateLimited(retryAt: retryAt))
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }
}
