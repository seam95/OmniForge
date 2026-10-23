import XCTest
@testable import OmniForge

/// 官方模型列表主动拉取：凭据、版本、缓存命中与 models_cache 兜底。
final class CodexOfficialModelsStoreTests: XCTestCase {
    private var dir: URL!
    private var cacheURL: URL!
    private var authURL: URL!
    private var modelsCacheURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexOfficialModelsStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("official.json")
        authURL = dir.appendingPathComponent("auth.json")
        modelsCacheURL = dir.appendingPathComponent("models_cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    private func writeAuth(sub: String = "user-1") throws {
        let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try writeJSON([
            "tokens": [
                "access_token": "access-token",
                "account_id": "acct-1",
                "id_token": "header.\(payload).signature",
            ],
        ], to: authURL)
    }

    private func writeModelsCache() throws {
        try writeJSON([
            "client_version": "0.163.0",
            "models": [["slug": "fallback-model", "visibility": "list"]],
        ], to: modelsCacheURL)
    }

    func test_storeFetchesWithCredentialsAndCachesModels() throws {
        try writeAuth()
        try writeModelsCache()
        var calls = 0
        let store = CodexOfficialModelsStore(
            cacheURL: cacheURL,
            now: { Date(timeIntervalSince1970: 10_000) },
            fetch: { request in
                calls += 1
                XCTAssertEqual(request.url?.host, "chatgpt.com")
                XCTAssertTrue(request.url?.query?.contains("client_version=0.163.0") == true)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
                let data = try! JSONSerialization.data(withJSONObject: [
                    "models": [
                        ["slug": "gpt-fetched", "visibility": "list", "context_window": 272_000],
                    ],
                ])
                return .success(.init(statusCode: 200, data: data, etag: "W/1"))
            }
        )

        XCTAssertEqual(store.rows(authURL: authURL, modelsCacheURL: modelsCacheURL)?.first?["slug"] as? String,
                       "fallback-model", "首次没有自己的缓存时回落 models_cache")

        let done = expectation(description: "refresh")
        store.refresh(authURL: authURL, modelsCacheURL: modelsCacheURL) { done.fulfill() }
        wait(for: [done], timeout: 3)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.rows(authURL: authURL, modelsCacheURL: modelsCacheURL)?.first?["slug"] as? String,
                       "gpt-fetched")
    }

    func test_storeUsesFreshCacheWithoutFetching() throws {
        try writeAuth()
        try writeModelsCache()
        try writeJSON([
            "identity": "acct-1|user-1",
            "clientVersion": "0.163.0",
            "fetchedAt": 10_000.0,
            "etag": "W/1",
            "models": [["slug": "cached-model", "visibility": "list"]],
        ], to: cacheURL)

        var calls = 0
        let store = CodexOfficialModelsStore(
            cacheURL: cacheURL,
            now: { Date(timeIntervalSince1970: 10_000 + 60) },
            fetch: { _ in
                calls += 1
                return .failure(NSError(domain: "test", code: 1))
            }
        )
        let done = expectation(description: "fresh refresh")
        done.isInverted = true
        store.refresh(authURL: authURL, modelsCacheURL: modelsCacheURL) { done.fulfill() }
        wait(for: [done], timeout: 0.3)

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.rows(authURL: authURL, modelsCacheURL: modelsCacheURL)?.first?["slug"] as? String,
                       "cached-model")
    }

    func test_storeRejectsCacheFromAnotherIdentity() throws {
        try writeAuth(sub: "user-2")
        try writeModelsCache()
        try writeJSON([
            "identity": "acct-1|user-1",
            "clientVersion": "0.163.0",
            "fetchedAt": 10_000.0,
            "models": [["slug": "other-user", "visibility": "list"]],
        ], to: cacheURL)

        let store = CodexOfficialModelsStore(cacheURL: cacheURL, fetch: { _ in
            .failure(NSError(domain: "test", code: 1))
        })
        XCTAssertEqual(store.rows(authURL: authURL, modelsCacheURL: modelsCacheURL)?.first?["slug"] as? String,
                       "fallback-model")
    }

    func test_normalizedBackfillsOfficialFields() throws {
        let fallback: [[String: Any]] = [[
            "slug": "gpt-known",
            "base_instructions": "OFFICIAL",
            "supports_reasoning_summaries": false,
            "supports_parallel_tool_calls": true,
            "visibility": "list",
            "shell_type": "unified_exec",
            "priority": 3,
        ]]
        let fetched: [[String: Any]] = [
            ["slug": "gpt-known", "context_window": 272_000],
            ["slug": "gpt-new", "visibility": "list"],
        ]
        let rows = CodexOfficialModelsStore.normalized(fetched, fallback: fallback)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["base_instructions"] as? String, "OFFICIAL")
        XCTAssertEqual(rows[0]["supports_reasoning_summaries"] as? Bool, false, "已有官方值优先")
        XCTAssertEqual(rows[0]["context_window"] as? Int, 272_000, "服务端值优先")
        XCTAssertEqual(rows[0]["priority"] as? Int, 0, "不继承另一行的 priority")
        XCTAssertEqual(rows[1]["base_instructions"] as? String,
                       CodexModelCatalogStore.neutralBaseInstructions, "没有官方模板时用中性指令兜底")
        XCTAssertEqual(rows[1]["visibility"] as? String, "list")
    }

    func test_validVersionAndJWTSubject() {
        XCTAssertEqual(CodexOfficialModelsStore.clientVersion(
            modelsCacheURL: modelsCacheURL, fileManager: .default
        ), nil, "文件不存在 → nil")
        XCTAssertTrue(CodexOfficialModelsStore.validVersion("0.163.0"))
        XCTAssertTrue(CodexOfficialModelsStore.validVersion("0.163.0-alpha.2"))
        XCTAssertFalse(CodexOfficialModelsStore.validVersion("0.0.0"))
        XCTAssertFalse(CodexOfficialModelsStore.validVersion("unknown"))

        let payload = Data(#"{"sub":"abc"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CodexOfficialModelsStore.jwtSubject("h.\(payload).s"), "abc")
        XCTAssertNil(CodexOfficialModelsStore.jwtSubject("not-a-jwt"))
    }
}
