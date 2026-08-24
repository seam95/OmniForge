import Foundation
import XCTest
@testable import OmniForge

/// 方舟 Coding Plan 限额 fetcher：无安装→未配置（零 spawn）、usage plan 主路径、
/// tier 兜底、失败磁盘缓存、缓存过期。
final class ArkCodingPlanLimitsFetcherTests: XCTestCase {
    private var runner: FakeArkCliRunner!
    private var cacheURL: URL!
    private var fetcher: ArkCodingPlanLimitsFetcher!

    override func setUpWithError() throws {
        runner = FakeArkCliRunner()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArkCodingPlanLimitsFetcherTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("ark-coding-plan-limits-cache.json")
        fetcher = ArkCodingPlanLimitsFetcher(runner: runner, cacheURL: cacheURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent())
    }

    private func usagePlanJSON(subscribed: Bool = true, tier: String? = "pro") -> String {
        let tierJSON = tier.map { #""tier":"\#($0)","# } ?? ""
        let periods = subscribed
            ? #"""
              "periods":[{"label":"session","percent":42,"reset_at":"2026-08-25T08:00:00Z"},
                          {"label":"weekly","percent":10,"reset_at":"2026-08-31T00:00:00Z"}]
              """#
            : #""periods":[]"#
        return #"""
        {"items":[{"product":"coding-plan","subscribed":\#(subscribed),\#(tierJSON)\#(periods)}]}
        """#
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
        runner.responses = ["usage plan --format json": usagePlanJSON(tier: "pro")]
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.planLabel, "Pro")
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

    func test_tierFallback_plansGet() async throws {
        fetcher.binaryOverride = "/usr/local/bin/arkcli"
        runner.responses = [
            "usage plan --format json": usagePlanJSON(tier: nil),
            "plans get --format json": #"{"plans":[{"key":"coding-plan","tier":"lite"}]}"#,
        ]
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.planLabel, "Lite", "usage 无 tier 时 plans get 兜底")
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
        XCTAssertEqual(tier, "Pro")
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