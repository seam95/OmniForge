import Foundation
import XCTest
@testable import OmniForge

private final class FakeOpencodeAPIKeyStore: OpencodeAPIKeyStoring {
    var storedKey: String?
    func readAPIKey() throws -> String? { storedKey }
    func writeAPIKey(_ apiKey: String) throws { storedKey = apiKey }
    func deleteAPIKey() throws { storedKey = nil }
}

/// opencode Go 限额 fetcher：钥匙串 / 环境变量 API key 守卫、rolling/weekly/monthly 窗口。
final class OpencodeLimitsFetcherTests: XCTestCase {

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
    }

    private func makeFetcher(
        keychainKey: String? = nil,
        envKey: String? = nil
    ) -> OpencodeLimitsFetcher {
        let keyStore = FakeOpencodeAPIKeyStore()
        keyStore.storedKey = keychainKey
        var environment: [String: String] = [:]
        if let envKey { environment["OPENCODE_GO_API_KEY"] = envKey }
        return OpencodeLimitsFetcher(
            session: URLProtocolStub.makeSession(),
            keyStore: keyStore,
            environment: environment
        )
    }

    func test_noApiKey_returnsNilWithoutNetwork() async throws {
        URLProtocolStub.stub = .init(statusCode: 500) // 不应被触达
        let result = try await makeFetcher(keychainKey: nil, envKey: nil).fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "无 key 零网络请求")
    }

    func test_keychainKeyPreferredOverEnvKey() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"usage":{"rolling":{"status":"ok","percent":20,"resetsAt":"2026-08-26T06:56:50.539Z"},\
        "weekly":{"status":"ok","percent":55,"resetsAt":"2026-08-31T00:00:00.539Z"},\
        "monthly":{"status":"ok","percent":80,"resetsAt":"2026-09-14T05:19:55.539Z"}}}
        """.utf8))
        let result = try await makeFetcher(keychainKey: "keychain-token", envKey: "env-token").fetchLimits(force: false)
        XCTAssertNotNil(result)
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer keychain-token", "优先使用钥匙串中的 API key")
    }

    func test_validEnvKey_fallbackWhenKeychainEmpty() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"usage":{"rolling":{"status":"ok","percent":20,"resetsAt":"2026-08-26T06:56:50.539Z"},\
        "weekly":{"status":"ok","percent":55,"resetsAt":"2026-08-31T00:00:00.539Z"},\
        "monthly":{"status":"ok","percent":80,"resetsAt":"2026-09-14T05:19:55.539Z"}}}
        """.utf8))
        let result = try await makeFetcher(keychainKey: nil, envKey: "env-token").fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 20)
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent, 55)
        XCTAssertEqual(result?.windows[.monthly]?.usedPercent, 80)
        XCTAssertEqual(
            result?.windows[.session]?.resetAt,
            UsageWindowParsing.parseResetDate("2026-08-26T06:56:50.539Z")
        )
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer env-token")
        XCTAssertEqual(request?.url?.absoluteString, "https://opencode.ai/zen/go/v1/usage")
    }

    func test_unauthorized_throwsReauth() async {
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await makeFetcher(keychainKey: "test-key").fetchLimits(force: false)
            XCTFail("401 → 应抛 reauth")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_emptyWindows_returnsNil() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("{}".utf8))
        let result = try await makeFetcher(keychainKey: "test-key").fetchLimits(force: false)
        XCTAssertNil(result, "无窗口 → 不显示限额卡")
    }

    func test_legacyShape_rollingUsageFallback() async throws {
        // 早期规范形状（顶层 rollingUsage + usagePercent/resetInSec 相对秒）。
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"rollingUsage":{"usagePercent":35,"resetInSec":7200},\
        "monthlyUsage":{"usagePercent":70,"resetInSec":864000}}
        """.utf8))
        let result = try await makeFetcher(keychainKey: "test-key").fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 35)
        XCTAssertEqual(result?.windows[.monthly]?.usedPercent, 70)
        XCTAssertNotNil(result?.windows[.session]?.resetAt, "resetInSec 相对秒换算 reset")
    }

    func test_incompleteModernWindow_fallsThroughToLegacy() async throws {
        // modern 对象存在但只有 reset 无百分比 → 回落可用的 legacy 窗口。
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"usage":{"rolling":{"resetsAt":"2026-08-26T06:56:50.539Z"}},\
        "rollingUsage":{"usagePercent":42,"resetInSec":600}}
        """.utf8))
        let result = try await makeFetcher(keychainKey: "test-key").fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 42, "不完整 modern 不吞 legacy")
    }

    func test_fractionPercent_convertedToHundredScale() async throws {
        // 0–1 小数比例 → 换算为百分比。
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"usage":{"rolling":{"percent":0.25,"resetsAt":"2026-08-26T06:56:50.539Z"}}}
        """.utf8))
        let result = try await makeFetcher(keychainKey: "test-key").fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.session]?.usedPercent ?? -1, 25, accuracy: 0.1)
    }
}
