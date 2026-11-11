import CryptoKit
import Foundation
import XCTest
@testable import OmniForge

/// enc:v2 凭据解密：格式解析、密钥指纹校验、钥匙串/环境变量密钥。
final class ZcodeCredentialCipherTests: XCTestCase {
    /// 固定 32 字节测试密钥。
    private let key = Data((0..<32).map { UInt8($0) })

    /// 按 ZCode 3.18 写入格式构造 v2 值。
    /// - Parameters:
    ///   - fingerprint: 覆盖指纹段（默认用真实密钥指纹）。
    private func sealedV2(
        _ plaintext: String,
        key: Data,
        source: String = "os",
        fingerprint: String? = nil
    ) throws -> String {
        let sealed = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key)
        )
        func encode(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        let fp = fingerprint ?? ZcodeCredentialCipher.keyFingerprint(key)
        return "enc:v2:\(source):\(fp):"
            + "\(encode(nonce)).\(encode(sealed.tag)).\(encode(sealed.ciphertext))"
    }

    func test_decryptV2_resolvesKeyBySource() throws {
        let value = try sealedV2("bigmodel", key: key)
        var requestedSource: String?
        let plain = ZcodeCredentialCipher.decryptV2(value) { source in
            requestedSource = source
            return self.key
        }
        XCTAssertEqual(plain, "bigmodel")
        XCTAssertEqual(requestedSource, "os")
    }

    func test_decryptV2_fingerprintMismatch_returnsNil() throws {
        let value = try sealedV2(
            "bigmodel",
            key: key,
            fingerprint: String(repeating: "0", count: 24)
        )
        XCTAssertNil(ZcodeCredentialCipher.decryptV2(value) { _ in self.key })
    }

    func test_decryptV2_missingOrWrongKey_returnsNil() throws {
        let value = try sealedV2("bigmodel", key: key)
        XCTAssertNil(ZcodeCredentialCipher.decryptV2(value) { _ in nil })
        XCTAssertNil(
            ZcodeCredentialCipher.decryptV2(value) { _ in Data(repeating: 1, count: 31) }
        )
    }

    func test_decryptV2_malformed_returnsNil() {
        XCTAssertNil(ZcodeCredentialCipher.decryptV2("enc:v2:os:abc") { _ in key })
        XCTAssertNil(ZcodeCredentialCipher.decryptV2("enc:v1:abc.def.ghi") { _ in key })
        XCTAssertNil(ZcodeCredentialCipher.decryptV2("plain-text") { _ in key })
        // 段长度不符（nonce 应为 12 字节）。
        XCTAssertNil(
            ZcodeCredentialCipher.decryptV2("enc:v2:os:\(String(repeating: "0", count: 24)):a.b.c") { _ in key }
        )
    }

    func test_keychainAccount_isSHA256HexOfCredentialsPath() {
        let path = "/Users/test/.zcode/v2/credentials.json"
        let expected = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            ZcodeCredentialCipher.keychainAccount(credentialsPath: path),
            expected
        )
        XCTAssertEqual(expected.count, 64)
    }

    func test_keyFromKeychainPassword_decodesBase64URL() {
        let password = ZcodeCredentialCipher.base64EncodedURLSafe(key)
        XCTAssertEqual(ZcodeCredentialCipher.key(fromKeychainPassword: password), key)
        XCTAssertNil(ZcodeCredentialCipher.key(fromKeychainPassword: "short"))
        XCTAssertNil(
            ZcodeCredentialCipher.key(fromKeychainPassword: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        )
    }

    func test_environmentKey_hashesSecretAndFileContent() throws {
        let secret = "test-managed-secret"
        let expected = Data(SHA256.hash(data: Data(secret.utf8)))
        XCTAssertEqual(
            ZcodeCredentialCipher.environmentKey(
                environment: ["ZCODE_CREDENTIAL_SECRET": secret]
            ),
            expected
        )

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-secret-\(UUID().uuidString)")
        try Data(secret.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(
            ZcodeCredentialCipher.environmentKey(
                environment: ["ZCODE_CREDENTIAL_SECRET_FILE": file.path]
            ),
            expected
        )
        XCTAssertNil(ZcodeCredentialCipher.environmentKey(environment: [:]))
    }

    func test_keyFingerprint_isFirst24HexChars() {
        let fp = ZcodeCredentialCipher.keyFingerprint(key)
        XCTAssertEqual(fp.count, 24)
        XCTAssertTrue(fp.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(fp, ZcodeCredentialCipher.keyFingerprint(key))
    }
}

// MARK: - 测试编码 helper

private extension ZcodeCredentialCipher {
    /// 32 字节密钥 → 43 字符 base64url（与钥匙串密码格式一致）。
    static func base64EncodedURLSafe(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
