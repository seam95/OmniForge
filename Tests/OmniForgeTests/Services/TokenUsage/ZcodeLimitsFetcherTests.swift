import CryptoKit
import Foundation
import XCTest
@testable import OmniForge

/// zcode 限额 fetcher：credentials.json 读取（明文 + enc:v1 解密）、balance 窗口。
final class ZcodeLimitsFetcherTests: XCTestCase {
    private var homeDir: URL!
    private var fetcher: ZcodeLimitsFetcher!

    override func setUpWithError() throws {
        homeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZcodeLimitsFetcherTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        fetcher = ZcodeLimitsFetcher(session: URLProtocolStub.makeSession())
        fetcher.homeOverride = homeDir
    }

    override func tearDownWithError() throws {
        URLProtocolStub.reset()
        try? FileManager.default.removeItem(at: homeDir)
    }

    private func writeCredentials(_ json: String) throws {
        let dir = homeDir.appendingPathComponent("v2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("credentials.json"))
    }

    /// 用同款方案加密测试值（sha256(secret) → AES-256-GCM）。
    private func encrypted(_ plaintext: String) throws -> String {
        let secret = "zcode-credential-fallback:darwin:\(homeDir.path):\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }
        return "enc:v1:\(iv.base64EncodedString()).\(sealed.tag.base64EncodedString()).\(sealed.ciphertext.base64EncodedString())"
    }

    private func balanceJSON() -> Data {
        Data("""
        {"data":{"server_time":1784502000,"balances":[\
        {"show_name":"GLM-5.2","plan_id":"start-plan","total_units":100,"used_units":40,"remaining_units":60,"period_end":1787097600},\
        {"show_name":"GLM-5-Turbo","total_units":50,"used_units":10,"remaining_units":40,"period_end":1787097600}]}}
        """.utf8)
    }

    func test_missingCredentials_returnsNil() async throws {
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty)
    }

    func test_plaintextJWT_buildsCreditsWindows() async throws {
        try writeCredentials(#"{"oauth:active_provider":"zai","zcodejwttoken":"jwt-plain"}"#)
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.configured, true)
        XCTAssertEqual(result?.windows[.credits]?.limit, 100, "主桶按 total 降序取最大")
        XCTAssertEqual(result?.windows[.credits]?.usedPercent, 40)
        XCTAssertEqual(result?.labeledWindows?.count, 1, "次桶 → labeled")
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-plain")
        XCTAssertEqual(request?.url?.absoluteString, "https://zcode.z.ai/api/v1/zcode-plan/billing/balance")
    }

    func test_encryptedJWT_decryptedAndUsed() async throws {
        let jwt = try encrypted("jwt-secret-1")
        try writeCredentials(#"{"oauth:active_provider":"bigmodel","zcodejwttoken":"\#(jwt)"}"#)
        URLProtocolStub.stub = .init(statusCode: 200, data: balanceJSON())
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNotNil(result)
        let request = URLProtocolStub.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-secret-1", "enc:v1 解密后取数")
    }

    func test_wrongActiveProvider_returnsNil() async throws {
        try writeCredentials(#"{"oauth:active_provider":"other","zcodejwttoken":"jwt"}"#)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result)
    }

    func test_badCredentials_returnsNil() async throws {
        try writeCredentials(#"{"oauth:active_provider":"zai","zcodejwttoken":"enc:v1:bad"}"#)
        let result = try await fetcher.fetchLimits(force: false)
        XCTAssertNil(result, "解密失败 fail-soft → 未配置，不崩溃")
    }
}