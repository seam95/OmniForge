import Foundation
import XCTest
@testable import OmniForge

/// Kimi kimi-code.json 读取 / home 解析（Kimi Code 优先，旧版回退）/ expires_at 临期判定 /
/// OAuth 刷新 / 原子写回（参考 08 / usage-limits.js resolveKimiHome..refreshKimiAccessToken）。
final class KimiAuthStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KimiAuthStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func mkdir(_ relative: String) throws -> URL {
        let dir = tmpDir.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeCreds(at dir: URL, _ object: [String: Any]) throws -> URL {
        let credsDir = dir.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credsDir, withIntermediateDirectories: true)
        let url = credsDir.appendingPathComponent("kimi-code.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    // MARK: - home 解析（Kimi Code 优先，旧版回退）

    func test_resolveHome_prefersCodeHomeWhenCredsPresent() throws {
        let codeHome = try mkdir(".kimi-code")
        try writeCreds(at: codeHome, ["access_token": "tok"])
        _ = try mkdir(".kimi")
        let home = KimiAuthFileCredentialReader.resolveKimiHome(homePath: tmpDir.path, environment: [:])
        XCTAssertEqual(home.path, codeHome.path, "kimi-code 持有登录 → 优先")
    }

    func test_resolveHome_fallsBackToLegacyWhenCodeHasNoCreds() throws {
        _ = try mkdir(".kimi-code")
        let legacy = try mkdir(".kimi")
        let home = KimiAuthFileCredentialReader.resolveKimiHome(homePath: tmpDir.path, environment: [:])
        XCTAssertEqual(home.path, legacy.path, "kimi-code 无凭证 → 旧版 ~/.kimi")
    }

    func test_resolveHome_honorsKimiHomeAndCodeHomeEnv() throws {
        let explicit = try mkdir("custom-kimi")
        XCTAssertEqual(
            KimiAuthFileCredentialReader.resolveKimiHome(homePath: tmpDir.path, environment: ["KIMI_HOME": explicit.path]).path,
            explicit.path,
            "KIMI_HOME 显式覆盖"
        )
        let customCode = try mkdir("custom-code")
        XCTAssertEqual(
            KimiAuthFileCredentialReader.resolveKimiHome(homePath: tmpDir.path, environment: ["KIMI_CODE_HOME": customCode.path]).path,
            customCode.path,
            "KIMI_CODE_HOME 显式覆盖（即使无凭证）"
        )
    }

    // MARK: - 凭证读取

    func test_readBundle_parsesExpiresAtSeconds() throws {
        let codeHome = try mkdir(".kimi-code")
        let url = try writeCreds(at: codeHome, [
            "access_token": "old-access",
            "refresh_token": "r-1",
            "expires_at": Double(1_800_003_600),
            "scope": "kimi-code",
            "token_type": "Bearer",
        ])
        let bundle = try XCTUnwrap(KimiAuthFileCredentialReader(credsURL: url).readBundle())
        XCTAssertEqual(bundle.accessToken, "old-access")
        XCTAssertEqual(bundle.refreshToken, "r-1")
        XCTAssertEqual(bundle.expiresAt, Date(timeIntervalSince1970: 1_800_003_600), "expires_at 秒 → Date")
        XCTAssertEqual(bundle.scope, "kimi-code")
        XCTAssertEqual(bundle.tokenType, "Bearer")
    }

    func test_readBundle_missingFileReturnsNil() throws {
        let missing = tmpDir.appendingPathComponent("credentials/kimi-code.json")
        XCTAssertNil(try KimiAuthFileCredentialReader(credsURL: missing).readBundle())
    }

    func test_readBundle_invalidPayloadThrows() throws {
        let codeHome = try mkdir(".kimi-code")
        let url = try writeCreds(at: codeHome, ["client_id": "no-access"])
        do {
            _ = try KimiAuthFileCredentialReader(credsURL: url).readBundle()
            XCTFail("expected invalidPayload throw")
        } catch let error as KimiAuthFileError {
            XCTAssertEqual(error, .invalidPayload)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - expires_at 临期判定

    func test_freshness_thirtySecondMargin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(KimiTokenFreshness.isStale(expiresAt: now.addingTimeInterval(29), now: now), "30 秒容差内 → 刷")
        XCTAssertTrue(KimiTokenFreshness.isStale(expiresAt: now.addingTimeInterval(-60), now: now), "已过期 → 刷")
        XCTAssertFalse(KimiTokenFreshness.isStale(expiresAt: now.addingTimeInterval(60), now: now), "远未过期不刷")
        XCTAssertFalse(KimiTokenFreshness.isStale(expiresAt: nil, now: now), "缺 expires_at 不触发（由 401 兜底）")
    }

    // MARK: - 刷新写回（tmp + rename，0600）

    func test_persist_mergesRotatedTokensAtomicallyWith0600() throws {
        let codeHome = try mkdir(".kimi-code")
        let url = try writeCreds(at: codeHome, [
            "access_token": "old-access",
            "refresh_token": "old-refresh",
            "expires_at": Double(1_800_000_000),
            "scope": "kimi-code",
            "token_type": "Bearer",
        ])
        let bundle = try XCTUnwrap(KimiAuthFileCredentialReader(credsURL: url).readBundle())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = try KimiAuthPersistence.persist(
            newTokens: KimiRefreshedTokens(
                accessToken: "new-access",
                refreshToken: "rotated-refresh",
                expiresIn: 3600,
                scope: nil,
                tokenType: nil
            ),
            into: bundle,
            now: now
        )
        XCTAssertEqual(updated.accessToken, "new-access")
        XCTAssertEqual(updated.refreshToken, "rotated-refresh")
        XCTAssertEqual(updated.scope, "kimi-code", "默认 scope 补全")
        XCTAssertEqual(updated.tokenType, "Bearer", "默认 token_type 补全")
        XCTAssertEqual(updated.expiresAt?.timeIntervalSince1970, 1_800_003_600, "expires_at = now + expires_in 秒")

        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(onDisk?["access_token"] as? String, "new-access")
        XCTAssertEqual(onDisk?["refresh_token"] as? String, "rotated-refresh")
        XCTAssertEqual((onDisk?["expires_at"] as? NSNumber)?.doubleValue, 1_800_003_600)
        XCTAssertEqual(onDisk?["scope"] as? String, "kimi-code")
        XCTAssertEqual(onDisk?["token_type"] as? String, "Bearer")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "凭证文件 0600")
        let staleTmp = try FileManager.default.contentsOfDirectory(atPath: codeHome.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(staleTmp.isEmpty, "无残留临时文件（原子写）")
    }

    func test_persist_keepsOldRefreshTokenWhenNoRotation() throws {
        let codeHome = try mkdir(".kimi-code")
        let url = try writeCreds(at: codeHome, ["access_token": "old", "refresh_token": "keep-refresh"])
        let bundle = try XCTUnwrap(KimiAuthFileCredentialReader(credsURL: url).readBundle())
        let updated = try KimiAuthPersistence.persist(
            newTokens: KimiRefreshedTokens(accessToken: "new", refreshToken: nil, expiresIn: 900, scope: nil, tokenType: nil),
            into: bundle,
            now: Date()
        )
        XCTAssertEqual(updated.refreshToken, "keep-refresh", "未轮换保留旧值")
    }

    // MARK: - OAuth 刷新

    func test_refresher_sendsFormBodyAndParsesResponse() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, KimiTokenRefresher.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Msh-Platform"), "kimi_cli")
            return .init(statusCode: 200, data: Data("""
            {"access_token":"fresh-access","refresh_token":"rotated","expires_in":2880,"scope":"kimi-code","token_type":"Bearer"}
            """.utf8))
        }
        let tokens = try await KimiTokenRefresher(session: URLProtocolStub.makeSession())
            .refresh(refreshToken: "r-1")
        XCTAssertEqual(tokens, KimiRefreshedTokens(
            accessToken: "fresh-access", refreshToken: "rotated", expiresIn: 2880, scope: "kimi-code", tokenType: "Bearer"
        ))
        let body = try XCTUnwrap(URLProtocolStub.recordedBodies.first)
        let payload = try XCTUnwrap(body.dictionaryFromFormURLEncoded())
        XCTAssertEqual(payload["client_id"], KimiTokenRefresher.oauthClientID)
        XCTAssertEqual(payload["grant_type"], "refresh_token")
        XCTAssertEqual(payload["refresh_token"], "r-1")
    }

    func test_refresher_401ForbiddenMapToRejected() async {
        for code in [401, 403] {
            URLProtocolStub.reset()
            URLProtocolStub.stub = .init(statusCode: code)
            do {
                _ = try await KimiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
                XCTFail("expected refreshRejected (HTTP \(code))")
            } catch let error as KimiTokenRefreshError {
                XCTAssertEqual(error, .refreshRejected)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func test_refresher_httpErrorAndInvalidResponse() async {
        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 503)
        do {
            _ = try await KimiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected httpError")
        } catch let error as KimiTokenRefreshError {
            XCTAssertEqual(error, .httpError(503))
        } catch {
            XCTFail("unexpected \(error)")
        }

        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("{}".utf8))
        do {
            _ = try await KimiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected invalidResponse")
        } catch let error as KimiTokenRefreshError {
            XCTAssertEqual(error, .invalidResponse, "缺 access_token")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_refresher_guardAndNetworkErrors() async {
        do {
            _ = try await KimiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "")
            XCTFail("expected noRefreshToken")
        } catch let error as KimiTokenRefreshError {
            XCTAssertEqual(error, .noRefreshToken)
        } catch {
            XCTFail("unexpected \(error)")
        }

        URLProtocolStub.reset()
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.notConnectedToInternet))
        do {
            _ = try await KimiTokenRefresher(session: URLProtocolStub.makeSession()).refresh(refreshToken: "r-1")
            XCTFail("expected network")
        } catch let error as KimiTokenRefreshError {
            guard case .network = error else { XCTFail("unexpected \(error)"); return }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
