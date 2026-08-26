import Foundation
import XCTest
@testable import OmniForge

private final class FakeArkCredentialsStore: ArkCredentialsStoring {
    var storedCredentials: ArkCredentials?
    func readCredentials() throws -> ArkCredentials? { storedCredentials }
    func writeCredentials(_ credentials: ArkCredentials) throws { storedCredentials = credentials }
    func deleteCredentials() throws { storedCredentials = nil }
}

/// 方舟 Coding Plan 限额 fetcher：AK/SK 直连、无安装→未配置（零 spawn）、usage plan 主路径、
/// tier 兜底、失败磁盘缓存、缓存过期。
final class ArkCodingPlanLimitsFetcherTests: XCTestCase {
    private var runner: FakeArkCliRunner!
    private var credentialsStore: FakeArkCredentialsStore!
    private var cacheURL: URL!
    private var fetcher: ArkCodingPlanLimitsFetcher!

    override func setUpWithError() throws {
        runner = FakeArkCliRunner()
        credentialsStore = FakeArkCredentialsStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArkCodingPlanLimitsFetcherTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("ark-coding-plan-limits-cache.json")
        fetcher = ArkCodingPlanLimitsFetcher(
            runner: runner,
            credentialsStore: credentialsStore,
            session: URLProtocolStub.makeSession(),
            environment: [:],
            cacheURL: cacheURL
        )
    }

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
    }

    private func usagePlanJSON(subscribed: Bool = true) -> String {
        let status = subscribed ? "Running" : "Stopped"
        let quotaUsage = subscribed
            ? #"""
              "QuotaUsage":[{"Level":"session","Percent":42,"ResetTimestamp":1787725175,"Cap":100},
                            {"Level":"weekly","Percent":10,"ResetTimestamp":1788105600,"Cap":100}]
              """#
            : #""QuotaUsage":[]"#
        return #"""
        {"Result":{"Status":"\#(status)",\#(quotaUsage)}}
        """#
    }

    // MARK: - AK/SK OpenAPI 直连

    func test_openApi_validCredentials_buildsLimits() async throws {
        credentialsStore.storedCredentials = ArkCredentials(accessKeyId: "AK-LIVE", secretAccessKey: "SK-LIVE")
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("""
        {"Result":{"Status":"Running","QuotaUsage":[{"Level":"session","Percent":50,"ResetTimestamp":1787725175,"Cap":100}]}}
        """.utf8))

        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertNil(result?.planLabel)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 50)
        XCTAssertEqual(result?.windows[.session]?.resetAt, Date(timeIntervalSince1970: 1_787_725_175))
        XCTAssertEqual(result?.windows[.session]?.limit, 100)
        XCTAssertEqual(result?.windows[.session]?.used, 50)
        XCTAssertEqual(result?.windows[.session]?.remaining, 50)
        XCTAssertEqual(runner.runCount, 0, "AK/SK OpenAPI 成功时零 spawn")

        let request = URLProtocolStub.recordedRequests.first
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Authorization")?.contains("Credential=AK-LIVE") == true)
    }

    func test_openApi_unauthorized_throwsReauth() async {
        credentialsStore.storedCredentials = ArkCredentials(accessKeyId: "AK-BAD", secretAccessKey: "SK-BAD")
        URLProtocolStub.stub = .init(statusCode: 401)

        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("401 应抛出 reauthRequired")
        } catch let error as LimitError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - 未安装

    func test_uninstalled_returnsNilWithoutSpawning() async throws {
        fetcher.installEvidenceOverride = false
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "无安装证据 → configured: false")
        XCTAssertEqual(runner.runCount, 0, "零 spawn")
    }

    // MARK: - 主路径

    func test_liveUsagePlan_buildsWindowsAndLabel() async throws {
        fetcher.binaryOverride = "/usr/local/bin/arkcli"
        runner.responses = ["usage plan --format json": usagePlanJSON()]
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertNil(result?.planLabel)
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 42)
        XCTAssertEqual(result?.windows[.weekly]?.usedPercent, 10)
        XCTAssertEqual(result?.windows[.session]?.unit, "calls")
        XCTAssertEqual(result?.stale, false)
    }

    func test_noSubscription_returnsNil() async throws {
        fetcher.binaryOverride = "/usr/local/bin/arkcli"
        runner.responses = ["usage plan --format json": usagePlanJSON(subscribed: false)]
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "无订阅 → configured: false")
    }

    func test_newStructureDoesNotUsePlansGetFallback() async throws {
        fetcher.binaryOverride = "/usr/local/bin/arkcli"
        runner.responses = [
            "usage plan --format json": usagePlanJSON(),
            "plans get --format json": #"{"plans":[{"key":"coding-plan","tier":"lite"}]}"#,
        ]
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result?.planLabel, "新结构不再从 plans get 补套餐名")
        XCTAssertEqual(runner.runCount, 1, "新结构不再调用 plans get")
    }

    // MARK: - 磁盘缓存兜底

    func test_failureFallsBackToDiskCache() async throws {
        fetcher.binaryOverride = "/usr/local/bin/arkcli"
        // 先写一份新鲜缓存。
        let payload = """
        {"planLabel":"Pro","profileIdentity":null,"cachedAt":\(Date().timeIntervalSince1970),\
        "windows":{"session":{"usedPercent":33,"resetAt":\(Date().addingTimeInterval(3600).timeIntervalSince1970)}}}
        """
        try Data(payload.utf8).write(to: cacheURL)

        runner.error = LimitError.network("arkcli failed")
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stale, true, "失败走 last-good 缓存")
        XCTAssertEqual(result?.windows[.session]?.usedPercent, 33)
        XCTAssertEqual(result?.issue, nil)
    }

    func test_cacheExpired_throwsLiveError() async throws {
        fetcher.binaryOverride = "/usr/local/bin/arkcli"
        let payload = """
        {"planLabel":"Pro","profileIdentity":null,"cachedAt":\(Date().addingTimeInterval(-86_400).timeIntervalSince1970),\
        "windows":{"session":{"usedPercent":33,"resetAt":\(Date().addingTimeInterval(3600).timeIntervalSince1970)}}}
        """
        try Data(payload.utf8).write(to: cacheURL)

        runner.error = LimitError.network("arkcli failed")
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("缓存过期且上游失败 → 应抛错")
        } catch let error as LimitError {
            XCTAssertEqual(error, .network("arkcli failed"))
        }
    }

    // MARK: - 解析纯函数

    func test_usageWindows_fromJSON() {
        let body = try! JSONSerialization.jsonObject(
            with: Data(usagePlanJSON().utf8)
        ) as! [String: Any]
        let (windows, tier) = ArkCodingPlanParsing.usageWindows(from: body)!
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[.session]?.usedPercent, 42)
        XCTAssertEqual(windows[.session]?.resetAt, Date(timeIntervalSince1970: 1_787_725_175))
        XCTAssertEqual(windows[.session]?.limit, 100)
        XCTAssertNil(tier)
    }

    func test_profileIdentity_extractsTrnAndKey() {
        let trn: [String: Any] = ["profile": ["owner_trn": "trn:iam::1234567890:root"]]
        XCTAssertEqual(ArkCodingPlanParsing.profileIdentity(from: trn), "1234567890")
        let key: [String: Any] = ["profile": ["identity_key": "volc-1234567890"]]
        XCTAssertEqual(ArkCodingPlanParsing.profileIdentity(from: key), "1234567890")
        let named: [String: Any] = ["profile": ["name": "seam", "user_id": "u-1"]]
        XCTAssertEqual(ArkCodingPlanParsing.profileIdentity(from: named), "seam:u-1")
        XCTAssertNil(ArkCodingPlanParsing.profileIdentity(from: [:]))
    }
}

// MARK: - 测试替身

private final class FakeArkCliRunner: ArkCliCommandRunning {
    var responses: [String: String] = [:]
    var error: Error?
    private(set) var runCount = 0

    func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        runCount += 1
        if let error { throw error }
        let key = arguments.joined(separator: " ")
        guard let response = responses[key] else {
            throw LimitError.network("unexpected command: \(key)")
        }
        return response
    }
}
