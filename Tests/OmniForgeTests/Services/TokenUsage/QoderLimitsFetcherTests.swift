import Foundation
import XCTest
@testable import OmniForge

/// qoder 限额 fetcher：IPC RPC 主路径、auth/status 套餐名、磁盘缓存兜底与过期。
final class QoderLimitsFetcherTests: XCTestCase {
    private var infoURL: URL!
    private var cacheURL: URL!
    private var fetcher: QoderLimitsFetcher!
    private var rpcResults: [String: Result<[String: Any], Error>] = [:]

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QoderLimitsFetcherTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        infoURL = dir.appendingPathComponent(".info.json")
        cacheURL = dir.appendingPathComponent("qoder-limits-cache.json")
        fetcher = QoderLimitsFetcher()
        fetcher.infoJSONURLOverride = infoURL
        fetcher.cacheFileURLOverride = cacheURL
        fetcher.rpcRequest = { [weak self] method, _, _ in
            guard let self, let result = self.rpcResults[method] else {
                throw LimitError.network("no stub for \(method)")
            }
            return try result.get()
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: infoURL.deletingLastPathComponent())
    }

    private func writeInfo(_ json: String) throws {
        try Data(json.utf8).write(to: infoURL)
    }

    private func creditUsage() -> [String: Any] {
        [
            "userQuota": ["used": 40, "total": 100, "remaining": 60, "percentage": 40, "unit": "credits"],
            "totalUsagePercentage": 40,
            "isQuotaExceeded": false,
            "expiresAt": "2026-09-01T00:00:00Z",
            "userType": "pro",
        ]
    }

    // MARK: - 主路径

    func test_rpcSuccess_buildsCreditsWindow() async throws {
        try writeInfo(#"{"ipcServerPath":"/tmp/qoder.sock"}"#)
        rpcResults["credit/usage"] = .success(creditUsage())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 40)
        XCTAssertEqual(result?.windows[.credits]?.limit, 100)
        XCTAssertEqual(result?.planLabel, "pro")
        XCTAssertEqual(result?.stale, false)
    }

    func test_rpcWithoutPlanLabel_authStatusFillsLabel() async throws {
        try writeInfo(#"{"ipcServerPath":"/tmp/qoder.sock"}"#)
        var usage = creditUsage()
        usage.removeValue(forKey: "userType")
        rpcResults["credit/usage"] = .success(usage)
        rpcResults["auth/status"] = .success(["userType": "free"])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.planLabel, "free", "auth/status 补套餐名")
    }

    func test_noIpcEndpoint_fallsBackToCache() async throws {
        try writeCachePayload(cachedAt: Date().timeIntervalSince1970, usedPercent: 33)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stale, true, "服务未运行 → last-good 缓存")
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 33)
    }

    func test_rpcFailure_fallsBackToCache() async throws {
        try writeInfo(#"{"ipcServerPath":"/tmp/qoder.sock"}"#)
        try writeCachePayload(cachedAt: Date().timeIntervalSince1970, usedPercent: 50)
        rpcResults["credit/usage"] = .failure(LimitError.network("rpc down"))
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 50)
        XCTAssertEqual(result?.stale, true)
    }

    func test_rpcUnparsableResponse_fallsBackToCache() async throws {
        // 服务在跑但响应形状漂移（无 userQuota）→ 仍走 last-good 缓存，不静默未配置。
        try writeInfo(#"{"ipcServerPath":"/tmp/qoder.sock"}"#)
        try writeCachePayload(cachedAt: Date().timeIntervalSince1970, usedPercent: 45)
        rpcResults["credit/usage"] = .success(["unrelated": "shape"])
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 45)
        XCTAssertEqual(result?.stale, true)
    }

    func test_cacheExpired_throws() async throws {
        try writeInfo(#"{"ipcServerPath":"/tmp/qoder.sock"}"#)
        try writeCachePayload(
            cachedAt: Date().addingTimeInterval(-8 * 86_400).timeIntervalSince1970,
            usedPercent: 50,
            resetAt: Date().addingTimeInterval(-86_400).timeIntervalSince1970 // 已重置
        )
        rpcResults["credit/usage"] = .failure(LimitError.network("rpc down"))
        do {
            _ = try await fetcher.fetchLimits(force: false)
            XCTFail("缓存过期且 RPC 失败 → 应抛错")
        } catch let error as LimitError {
            XCTAssertEqual(error, .network("rpc down"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_cacheOlderThanTTL_resetInFuture_retained() async throws {
        // 超过 7 天但重置时间仍在未来 → 保留（服务长期不在线仍能显示本周期额度）。
        try writeCachePayload(
            cachedAt: Date().addingTimeInterval(-8 * 86_400).timeIntervalSince1970,
            usedPercent: 55,
            resetAt: Date().addingTimeInterval(86_400).timeIntervalSince1970
        )
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.stale, true)
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 55)
    }

    func test_defaultInfoPath_resolvesSharedCacheRoot() async throws {
        // 默认安装布局：<QODER_HOME>/SharedClientCache/{.info.json, cache/db/local.db}；
        // .info.json 在 SharedClientCache 根部，不可再拼一层目录。
        let home = infoURL.deletingLastPathComponent()
            .appendingPathComponent("QoderDefaultHome_\(UUID().uuidString)", isDirectory: true)
        let shared = home.appendingPathComponent("SharedClientCache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("cache/db", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"ipcServerPath":"/tmp/qoder-default.sock"}"#.utf8)
            .write(to: shared.appendingPathComponent(".info.json"))
        setenv("QODER_HOME", home.path, 1)
        defer { unsetenv("QODER_HOME") }

        let defaultFetcher = QoderLimitsFetcher()
        defaultFetcher.cacheFileURLOverride = cacheURL
        var receivedSocket: String?
        defaultFetcher.rpcRequest = { method, socketPath, _ in
            receivedSocket = socketPath
            return ["userQuota": ["used": 1, "total": 10, "remaining": 9]]
        }
        let result = try await defaultFetcher.fetchLimits(force: false)
        XCTAssertEqual(receivedSocket, "/tmp/qoder-default.sock", "默认路径应命中 SharedClientCache/.info.json")
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 10)
    }

    // MARK: - 解析纯函数

    func test_creditWindow_quotaExceededPinsHundred() {
        var response = creditUsage()
        response["isQuotaExceeded"] = true
        response["totalUsagePercentage"] = 40
        let (window, _) = QoderLimitsParsing.creditWindow(from: response)!
        XCTAssertEqual(window.usedPercent, 100, "超限钉死 100%")
    }

    func test_creditWindow_noExpirySentinelDropsReset() {
        var response = creditUsage()
        response["expiresAt"] = "9999-12-31T00:00:00Z"
        let (window, _) = QoderLimitsParsing.creditWindow(from: response)!
        XCTAssertNil(window.resetAt, "Free 无过期哨兵 → 不显示重置时间")
    }

    func test_creditWindow_epochSecondsExpiryParses() {
        var response = creditUsage()
        response["expiresAt"] = Date().addingTimeInterval(3_600).timeIntervalSince1970
        let (window, _) = QoderLimitsParsing.creditWindow(from: response)!
        XCTAssertNotNil(window.resetAt, "epoch 秒数字过期时间可解析")
    }

    // MARK: - 工具

    private func writeCachePayload(cachedAt: Double, usedPercent: Double, resetAt: Double? = nil) throws {
        let payload: [String: Any] = [
            "planLabel": "pro",
            "cachedAt": cachedAt,
            "window": [
                "usedPercent": usedPercent,
                "limit": 100, "used": 40, "remaining": 60,
                "resetAt": resetAt ?? Date().addingTimeInterval(86_400).timeIntervalSince1970,
                "unit": "credits",
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: cacheURL)
    }
}