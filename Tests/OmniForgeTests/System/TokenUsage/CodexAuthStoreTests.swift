import Foundation
import XCTest
@testable import OmniForge

/// Codex auth.json 读取 / JWT 过期判定 / 刷新失败细分 / 原子写回（参考 04 / 08 / codex-token-refresh.js）。
final class CodexAuthStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuthStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - auth.json 读取

    func test_defaultAuthURL_honorsCodexHomeOverride() {
        let url = CodexAuthFileCredentialReader.defaultAuthURL(
            environment: ["CODEX_HOME": "/tmp/custom-codex"]
        )
        XCTAssertEqual(url.path, "/tmp/custom-codex/auth.json")
    }

    func test_defaultAuthURL_fallsBackToHomeDotCodex() {
        let url = CodexAuthFileCredentialReader.defaultAuthURL(
            homePath: "/Users/fake", environment: [:]
        )
        XCTAssertEqual(url.path, "/Users/fake/.codex/auth.json")
    }

    func test_readBundle_parsesCredentials() throws {
        let url = try writeAuthJSON([
            "last_refresh": "2026-08-20T00:00:00.000Z",
            "openid1": "keep-me",
            "tokens": [
                "access_token": jwtForAuthNamespace(["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct-123"]),
                "id_token": jwtForAuthNamespace(["chatgpt_plan_type": "pro"]),
                "refresh_token": "r-1",
                "account_id": "acct-raw",
            ],
        ])
        let bundle = try XCTUnwrap(CodexAuthFileCredentialReader(authURL: url).readBundle())
        XCTAssertTrue(bundle.accessToken.hasPrefix("eyJ"), "JWT access token 原样保留")
        XCTAssertEqual(bundle.refreshToken, "r-1")
        XCTAssertEqual(bundle.idToken, jwtForAuthNamespace(["chatgpt_plan_type": "pro"]))
        XCTAssertEqual(bundle.lastRefresh, "2026-08-20T00:00:00.000Z")
        XCTAssertEqual(bundle.accountID, "acct-raw", "tokens.account_id 优先于 JWT 声明")
        XCTAssertEqual(bundle.planType, "plus", "access JWT 命名空间取套餐")
        XCTAssertEqual((bundle.raw["openid1"] as? String), "keep-me", "原始字典保留给写回合并")
    }

    func test_readBundle_missingFileReturnsNil() throws {
        let missing = tmpDir.appendingPathComponent("nope.json")
        XCTAssertNil(try CodexAuthFileCredentialReader(authURL: missing).readBundle())
    }

    func test_readBundle_invalidPayloadThrows() throws {
        let url = try writeAuthJSON(["tokens": ["client_id": "no-access"] ])
        do {
            _ = try CodexAuthFileCredentialReader(authURL: url).readBundle()
            XCTFail("expected invalidPayload throw")
        } catch let error as CodexAuthFileError {
            XCTAssertEqual(error, .invalidPayload)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - 套餐与账号提取

    func test_planExtractor_displayablePlans() {
        XCTAssertEqual(
            CodexPlanExtractor.displayablePlan(
                accessToken: jwtForAuthNamespace(["chatgpt_plan_type": "premium"]),
                idToken: nil
            ),
            "Premium", "显示套餐名清洗首字母大写"
        )
        XCTAssertEqual(
            CodexPlanExtractor.displayablePlan(
                accessToken: nil,
                idToken: jwtForAuthNamespace(["chatgpt_plan_type": "plus"])
            ),
            "Plus", "access 缺时用 id_token 兜底"
        )
        XCTAssertNil(CodexPlanExtractor.displayablePlan(
            accessToken: jwtForAuthNamespace(["chatgpt_plan_type": "free"]), idToken: nil
        ), "free/none/unknown 不可显示")
        XCTAssertNil(CodexPlanExtractor.displayablePlan(accessToken: "not-a-jwt", idToken: nil))
    }

    func test_planExtractor_accountID_fromJwt() {
        XCTAssertEqual(
            CodexPlanExtractor.accountID(
                fromAuthTokenRaw: nil,
                accessToken: jwtForAuthNamespace(["chatgpt_account_id": "acct-jwt"]),
                idToken: nil
            ),
            "acct-jwt"
        )
        XCTAssertEqual(
            CodexPlanExtractor.accountID(
                fromAuthTokenRaw: "acct-raw",
                accessToken: jwtForAuthNamespace(["chatgpt_account_id": "acct-jwt"]),
                idToken: nil
            ),
            "acct-raw", "auth.json 显式 account_id 优先"
        )
        XCTAssertNil(CodexPlanExtractor.accountID(fromAuthTokenRaw: nil, accessToken: "x.y.z", idToken: nil))
    }

    // MARK: - JWT 过期与「临期才刷」

    func test_freshness_expiration_readsJwtExpInSeconds() {
        let exp = Date(timeIntervalSince1970: 1_800_000_000)
        let token = makeJWT(payload: ["exp": 1_800_000_000])
        let parsed = CodexTokenFreshness.expiration(of: token)
        XCTAssertEqual(parsed?.timeIntervalSince1970, exp.timeIntervalSince1970)
        XCTAssertNil(CodexTokenFreshness.expiration(of: "opaque-token"))
        XCTAssertNil(CodexTokenFreshness.expiration(of: "a.b.c"))
    }

    func test_freshness_stale_whenExpiryWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = makeJWT(payload: ["exp": 1_800_000_000 + 60]) // 1 分钟后过期
        XCTAssertTrue(CodexTokenFreshness.isStale(
            accessToken: token, lastRefresh: nil, now: now
        ), "临期（≤5 分钟）+ 必须刷新")
        let fresh = makeJWT(payload: ["exp": 1_800_000_000 + 600])
        XCTAssertFalse(CodexTokenFreshness.isStale(
            accessToken: fresh, lastRefresh: nil, now: now
        ), "远未过期不刷")
    }

    func test_freshness_opaqueTokensFallBackToLastRefreshAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(CodexTokenFreshness.isStale(
            accessToken: "opaque", lastRefresh: nil, now: now
        ), "无 exp 且无 last_refresh → 认为过期")
        let weekAgo = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7 * 86_400))
        XCTAssertFalse(CodexTokenFreshness.isStale(
            accessToken: "opaque", lastRefresh: weekAgo, now: now
        ), "8 天内不刷")
        let nineDaysAgo = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * 86_400))
        XCTAssertTrue(CodexTokenFreshness.isStale(
            accessToken: "opaque", lastRefresh: nineDaysAgo, now: now
        ), "超过 8 天 → 过期需要刷新")
    }

    // MARK: - 原子写回（tmp + rename，0600）

    func test_persist_mergesTokensAtomicallyWith0600() throws {
        let url = try writeAuthJSON([
            "last_refresh": "2026-08-20T00:00:00.000Z",
            "openid1": "keep-me",
            "tokens": [
                "access_token": "old-access",
                "id_token": "old-id",
                "refresh_token": "old-refresh",
            ],
        ])
        let bundle = try XCTUnwrap(CodexAuthFileCredentialReader(authURL: url).readBundle())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = try CodexAuthPersistence.persist(
            newTokens: CodexRefreshedTokens(
                accessToken: "new-access", refreshToken: "rotated-refresh", idToken: "new-id"
            ),
            into: bundle,
            now: now
        )

        XCTAssertEqual(updated.accessToken, "new-access")
        XCTAssertEqual(updated.refreshToken, "rotated-refresh")
        XCTAssertEqual(updated.idToken, "new-id")

        let onDisk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        let tokens = onDisk?["tokens"] as? [String: Any]
        XCTAssertEqual(tokens?["access_token"] as? String, "new-access")
        XCTAssertEqual(tokens?["refresh_token"] as? String, "rotated-refresh")
        XCTAssertEqual(onDisk?["openid1"] as? String, "keep-me", "无关字段保留")
        XCTAssertNotNil(onDisk?["last_refresh"], "last_refresh 更新为 ISO")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "凭证文件 0600")
        let staleTmp = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(staleTmp.isEmpty, "无残留临时文件（原子写）")
    }

    func test_persist_keepsOldRefreshTokenWhenResponseOmitsRotation() throws {
        let url = try writeAuthJSON([
            "tokens": ["access_token": "old", "refresh_token": "keep-refresh"],
        ])
        let bundle = try XCTUnwrap(CodexAuthFileCredentialReader(authURL: url).readBundle())
        let updated = try CodexAuthPersistence.persist(
            newTokens: CodexRefreshedTokens(accessToken: "new", refreshToken: nil, idToken: nil),
            into: bundle,
            now: Date()
        )
        XCTAssertEqual(updated.refreshToken, "keep-refresh", "未轮换的 refresh token 保留旧值")
    }

    // MARK: - 刷新失败细分

    func test_refresher_sendsRefreshGrant_andReturnsTokens() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, CodexTokenRefresher.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return .init(statusCode: 200, data: Data("""
            {"access_token":"fresh-access","refresh_token":"rotated","id_token":"fresh-id"}
            """.utf8))
        }
        let tokens = try await CodexTokenRefresher(session: URLProtocolStub.makeSession())
            .refresh(refreshToken: "r-1")
        XCTAssertEqual(tokens, CodexRefreshedTokens(
            accessToken: "fresh-access", refreshToken: "rotated", idToken: "fresh-id"
        ))

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(URLProtocolStub.recordedBodies.first)
        let payload = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        )
        XCTAssertEqual(payload["client_id"] as? String, CodexTokenRefresher.clientID)
        XCTAssertEqual(payload["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(payload["refresh_token"] as? String, "r-1")
    }

    func test_refresher_maps401ToExplicitReasons() async {
        let reasons: [(code: String, expected: CodexTokenRefreshError)] = [
            ("refresh_token_expired", .refreshTokenExpired),
            ("refresh_token_reused", .refreshTokenReused),
            ("refresh_token_invalidated", .refreshTokenInvalidated),
        ]
        for reason in reasons {
            URLProtocolStub.reset()
            URLProtocolStub.handler = { _ in
                .init(statusCode: 401, data: Data(#"{"error":{"code":"\#(reason.code)"}}"#.utf8))
            }
            do {
                _ = try await CodexTokenRefresher(session: URLProtocolStub.makeSession())
                    .refresh(refreshToken: "r-1")
                XCTFail("expected failure for \(reason.code)")
            } catch let error as CodexTokenRefreshError {
                XCTAssertEqual(error, reason.expected, "细分 \(reason.code)")
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func test_refresher_unknown401ReasonIsGenericRejected() async {
        URLProtocolStub.reset()
        URLProtocolStub.handler = { _ in .init(statusCode: 401, data: Data(#"{"error":"invalid_grant"}"#.utf8)) }
        do {
            _ = try await CodexTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected failure")
        } catch let error as CodexTokenRefreshError {
            XCTAssertEqual(error, .refreshRejected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refresher_httpErrorAndInvalidResponse() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 503)
        do {
            _ = try await CodexTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected failure")
        } catch let error as CodexTokenRefreshError {
            XCTAssertEqual(error, .httpError(503))
        } catch {
            XCTFail("unexpected \(error)")
        }

        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("{}".utf8))
        do {
            _ = try await CodexTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected failure")
        } catch let error as CodexTokenRefreshError {
            XCTAssertEqual(error, .invalidResponse, "缺 access_token → 无效响应")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refresher_guardMissingRefreshToken() async {
        do {
            _ = try await CodexTokenRefresher(session: URLProtocolStub.makeSession())
                .refresh(refreshToken: "")
            XCTFail("expected failure")
        } catch let error as CodexTokenRefreshError {
            XCTAssertEqual(error, .noRefreshToken)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refresher_networkErrorMapsToNetwork() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.notConnectedToInternet))
        do {
            _ = try await CodexTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected failure")
        } catch let error as CodexTokenRefreshError {
            guard case .network = error else { XCTFail("unexpected \(error)"); return }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - 工具

    private func writeAuthJSON(_ object: [String: Any]) throws -> URL {
        let url = tmpDir.appendingPathComponent("auth.json")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
        return url
    }

    /// 构造测试 JWT（header.payload.sig，payload 为 auth 命名空间字典）。
    private func jwtForAuthNamespace(_ namespaceClaims: [String: Any]) -> String {
        let payload: [String: Any] = [
            CodexPlanExtractor.authNamespace: namespaceClaims,
        ]
        return makeJWT(payload: payload)
    }

    private func makeJWT(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let base64url = { (data: Data) -> String in
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64url(header)).\(base64url(payloadData)).sig"
    }
}
