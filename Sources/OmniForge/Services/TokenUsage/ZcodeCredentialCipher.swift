import CryptoKit
import Foundation
import Security

// MARK: - 钥匙串读取

/// 通用密码项读取抽象（测试可注入）。
protocol KeychainPasswordReading {
    /// 读取指定 service/account 的通用密码；不存在或无权限 → nil。
    func password(service: String, account: String) -> String?
}

/// 基于 Security framework 的系统钥匙串实现。
struct SystemKeychainPasswordReader: KeychainPasswordReading {
    func password(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - enc:v2 解密

/// ZCode 3.18+ 凭据封装：`enc:v2:<source>:<key指纹24hex>:<nonce>.<tag>.<ciphertext>`。
/// 三段载荷均为 base64url；算法 AES-256-GCM（nonce 12 字节、tag 16 字节）。
///
/// 密钥来源两态：
/// - `os`：系统钥匙串的 32 字节随机密钥（service `ZCode Credential Encryption`，
///   account 为 credentials.json 绝对路径的 SHA256）。
/// - `env`：`ZCODE_CREDENTIAL_SECRET` 或 `ZCODE_CREDENTIAL_SECRET_FILE` 内容的
///   SHA256。
///
/// 解析失败、密钥缺失、指纹不匹配一律返回 nil（fail-soft，绝不崩溃）。
enum ZcodeCredentialCipher {
    /// 系统钥匙串中的 service 名（与 ZCode 客户端一致）。
    static let keychainService = "ZCode Credential Encryption"
    /// v2 载荷前缀。
    static let v2Prefix = "enc:v2:"

    /// 解密 v2 值。
    /// - Parameters:
    ///   - value: 完整的 `enc:v2:...` 字符串。
    ///   - resolveKey: 按 source（`os` / `env`）返回 32 字节密钥。
    static func decryptV2(_ value: String, resolveKey: (String) -> Data?) -> String? {
        guard value.hasPrefix(v2Prefix) else { return nil }
        // `v2:<source>:<指纹>:<密封>`，指纹后是含点号的三段密封。
        let parts = value.dropFirst(v2Prefix.count).split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3 else { return nil }
        let source = String(parts[0])
        let fingerprint = String(parts[1])
        let segments = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let nonce = base64Decoded(segments[0]), nonce.count == 12,
              let tag = base64Decoded(segments[1]), tag.count == 16,
              let ciphertext = base64Decoded(segments[2]),
              let key = resolveKey(source), key.count == 32
        else { return nil }
        // 指纹 = sha256(key) 前 24 个 hex 字符；不匹配说明密钥已轮换。
        guard keyFingerprint(key) == fingerprint else { return nil }
        let symmetricKey = SymmetricKey(data: key)
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        ), let plaintext = try? AES.GCM.open(box, using: symmetricKey),
           let string = String(data: plaintext, encoding: .utf8),
           !string.isEmpty
        else { return nil }
        return string
    }

    /// 钥匙串密码（43 字符 base64url）→ 32 字节密钥。
    static func key(fromKeychainPassword password: String) -> Data? {
        guard let data = base64Decoded(Substring(password)), data.count == 32 else {
            return nil
        }
        return data
    }

    /// 钥匙串账户名：credentials.json 绝对路径的 SHA256 十六进制。
    static func keychainAccount(credentialsPath: String) -> String {
        SHA256.hash(data: Data(credentialsPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 环境变量密钥：明文 secret 或 secret 文件内容的 SHA256。
    static func environmentKey(environment: [String: String]) -> Data? {
        if let secret = environment["ZCODE_CREDENTIAL_SECRET"], !secret.isEmpty {
            return Data(SHA256.hash(data: Data(secret.utf8)))
        }
        if let path = environment["ZCODE_CREDENTIAL_SECRET_FILE"], !path.isEmpty,
           let content = try? String(contentsOfFile: path, encoding: .utf8),
           !content.isEmpty {
            return Data(SHA256.hash(data: Data(content.utf8)))
        }
        return nil
    }

    /// 密钥指纹：sha256(key) 的前 24 个 hex 字符。
    static func keyFingerprint(_ key: Data) -> String {
        let hex = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(24))
    }

    /// base64url / 标准 base64 统一解码：字母表归一后重排 padding。
    static func base64Decoded(_ encoded: Substring) -> Data? {
        var standard = String(encoded)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "=", with: "")
        while standard.count % 4 != 0 { standard += "=" }
        return Data(base64Encoded: standard)
    }
}
