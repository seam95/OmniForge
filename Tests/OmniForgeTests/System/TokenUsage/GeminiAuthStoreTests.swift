import Foundation
import XCTest
@testable import OmniForge

/// Gemini oauth_creds.json 读取 / expiry_date 过期判定 / OAuth 刷新 / 原子写回
/// （参考 08 / usage-limits.js resolveGeminiHome..refreshGeminiAccessToken）。
final class GeminiAuthStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiAuthStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - oauth_creds.json 读取

    func test_defaultCredsURL_honorsGeminiHomeOverride() {
        let url = GeminiAuthFileCredentialReader.defaultCredsURL(
            environment: ["GEMINI_HOME": "/tmp/custom-gemini"]
        )
        XCTAssertEqual(url.path, "/tmp/custom-gemini/oauth_creds.json")
    }

    func test_defaultCredsURL_fallsBackToHomeDotGemini() {
        let url = GeminiAuthFileCredentialReader.defaultCredsURL(
            homePath: "/Users/fake", environment: [:]
        )
        XCTAssertEqual(url.path, "/Users/fake/.gemini/oauth_creds.json")
    }

    func test_readBundle_parsesCredentials() throws {
        let url = try writeCreds([
            "access_token": "old-access",
            "refresh_token": "r-1",
            "id_token": "id-1",
            "expiry_date": 1_800_100_000_000,
            "theme": "dark",
        ])
        let bundle = try XCTUnwrap(GeminiAuthFileCredentialReader(credsURL: url).readBundle())
        XCTAssertEqual(bundle.accessToken, "old-access")
        XCTAssertEqual(bundle.refreshToken, "r-1")
        XCTAssertEqual(bundle.idToken, "id-1")
        XCTAssertEqual(bundle.expiryDate, Date(timeIntervalSince1970: 1_800_100_000), "expiry_date 毫秒 → Date")
        XCTAssertEqual((bundle.raw["theme"] as? String), "dark", "原始字段保留给写回合并")
    }

    func test_readBundle_missingFileReturnsNil() throws {
        let missing = tmpDir.appendingPathComponent("nope.json")
        XCTAssertNil(try GeminiAuthFileCredentialReader(credsURL: missing).readBundle())
    }

    func test_readBundle_invalidPayloadThrows() throws {
        let url = try writeCreds(["client_id": "no-access"])
        do {
            _ = try GeminiAuthFileCredentialReader(credsURL: url).readBundle()
            XCTFail("expected invalidPayload throw")
        } catch let error as GeminiAuthFileError {
            XCTAssertEqual(error, .invalidPayload)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_readBundle_expiryMissingKeepsNil() throws {
        let url = try writeCreds(["access_token": "tok-1"])
        let bundle = try XCTUnwrap(GeminiAuthFileCredentialReader(credsURL: url).readBundle())
        XCTAssertNil(bundle.expiryDate, "无 expiry_date → nil（按参考：缺省不视为过期）")
    }

    // MARK: - expiry_date 临期判定

    func test_freshness_staleOnlyWhenExpiryPassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(GeminiTokenFreshness.isStale(expiryDate: now.addingTimeInterval(-1), now: now), "已过期 → 刷")
        XCTAssertFalse(GeminiTokenFreshness.isStale(expiryDate: now.addingTimeInterval(3600), now: now), "远未过期不刷")
        XCTAssertFalse(GeminiTokenFreshness.isStale(expiryDate: nil, now: now), "参考口径：expiry 缺失不触发（由 401 兜底）")
    }

    // MARK: - 刷新写回（tmp + rename，0600）

    func test_persist_mergesTokensAtomicallyWith0600() throws {
        let url = try writeCreds([
            "access_token": "old-access",
            "refresh_token": "r-1",
            "id_token": "old-id",
            "theme": "dark",
        ])
        let bundle = try XCTUnwrap(GeminiAuthFileCredentialReader(credsURL: url).readBundle())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = try GeminiAuthPersistence.persist(
            newTokens: GeminiRefreshedTokens(accessToken: "new-access", idToken: "new-id", expiresIn: 3600),
            into: bundle,
            now: now
        )

        XCTAssertEqual(updated.accessToken, "new-access")
        XCTAssertEqual(updated.idToken, "new-id")
        XCTAssertEqual(updated.refreshToken, "r-1", "refresh_token 保留")

        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(onDisk?["access_token"] as? String, "new-access")
        XCTAssertEqual(onDisk?["refresh_token"] as? String, "r-1")
        XCTAssertEqual(onDisk?["id_token"] as? String, "new-id")
        XCTAssertEqual(onDisk?["expiry_date"] as? NSNumber, 1_800_003_600_000, "expiry_date = now + expires_in*1000")
        XCTAssertEqual(onDisk?["theme"] as? String, "dark", "无关字段保留")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "凭证文件 0600")
        let staleTmp = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(staleTmp.isEmpty, "无残留临时文件（原子写）")
    }

    func test_persist_missingIdTokenKeepsOld() throws {
        let url = try writeCreds(["access_token": "old", "refresh_token": "r-1", "id_token": "keep"])
        let bundle = try XCTUnwrap(GeminiAuthFileCredentialReader(credsURL: url).readBundle())
        let updated = try GeminiAuthPersistence.persist(
            newTokens: GeminiRefreshedTokens(accessToken: "new", idToken: nil, expiresIn: 900),
            into: bundle,
            now: Date()
        )
        XCTAssertEqual(updated.idToken, "keep", "响应缺 id_token 保留旧值")
    }

    // MARK: - OAuth 刷新

    func test_refresher_sendsFormBody_andParsesResponse() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, GeminiTokenRefresher.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            return .init(statusCode: 200, data: Data("""
            {"access_token":"fresh-access","id_token":"fresh-id","expires_in":3599}
            """.utf8))
        }
        let tokens = try await GeminiTokenRefresher(session: URLProtocolStub.makeSession())
            .refresh(refreshToken: "r-1")
        XCTAssertEqual(tokens.accessToken, "fresh-access")
        XCTAssertEqual(tokens.idToken, "fresh-id")
        XCTAssertEqual(tokens.expiresIn, 3599)

        let body = try XCTUnwrap(URLProtocolStub.recordedBodies.first)
        let payload = try XCTUnwrap(body.dictionaryFromFormURLEncoded())
        XCTAssertEqual(payload["client_id"], GeminiTokenRefresher.oauthClientID)
        XCTAssertEqual(payload["client_secret"], GeminiTokenRefresher.oauthClientSecret)
        XCTAssertEqual(payload["grant_type"], "refresh_token")
        XCTAssertEqual(payload["refresh_token"], "r-1")
    }

    func test_refresher_401MapsToRejected() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 401)
        do {
            _ = try await GeminiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected refreshRejected")
        } catch let error as GeminiTokenRefreshError {
            XCTAssertEqual(error, .refreshRejected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refresher_httpErrorAndInvalidResponse() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 503)
        do {
            _ = try await GeminiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected httpError")
        } catch let error as GeminiTokenRefreshError {
            XCTAssertEqual(error, .httpError(503))
        } catch {
            XCTFail("unexpected \(error)")
        }

        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("{}".utf8))
        do {
            _ = try await GeminiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected invalidResponse")
        } catch let error as GeminiTokenRefreshError {
            XCTAssertEqual(error, .invalidResponse, "缺 access_token")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refresher_guardAndNetworkErrors() async {
        do {
            _ = try await GeminiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "")
            XCTFail("expected noRefreshToken")
        } catch let error as GeminiTokenRefreshError {
            XCTAssertEqual(error, .noRefreshToken)
        } catch {
            XCTFail("unexpected \(error)")
        }

        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.notConnectedToInternet))
        do {
            _ = try await GeminiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected network")
        } catch let error as GeminiTokenRefreshError {
            guard case .network = error else { XCTFail("unexpected \(error)"); return }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - 工具

    private func writeCreds(_ object: [String: Any]) throws -> URL {
        let url = tmpDir.appendingPathComponent("oauth_creds.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }
}

