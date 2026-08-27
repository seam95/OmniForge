import Foundation
import Security

// MARK: - 协议边界

/// Claude 凭证读取边界 — 探测存在性与读秘密分离（参考 04）。
protocol ClaudeCredentialReading {
    /// 只探测条目是否存在（不读密码）— 区分「从未登录」vs「登录过期」。
    func probe() -> Bool
    /// 读取 OAuth access token；条目不存在 → nil。
    func readAccessToken() throws -> String?
    /// 本地解码套餐（如 "Pro" / "Max"）；无信息 → nil。
    func planLabel() -> String?
}

/// 凭证读取失败（Keychain 交互被拒 / 解码失败等）；调用方降级为「未配置」。
enum CredentialReadError: Error, Equatable {
    case keychainUnavailable(OSStatus)
    case invalidPayload
}

// MARK: - Claude Keychain 实现

/// Claude Code 的 Keychain 服务名（参考 04/08；macOS 专属）。
enum ClaudeKeychain {
    static let credentialService = "Claude Code-credentials"
}

/// 用 Security 框架读 Claude Code 写入的 Keychain 条目。
/// 注意：读另一 App 的条目会触发系统授权弹窗——这是预期行为（ADR-0002）。
final class ClaudeKeychainCredentialReader: ClaudeCredentialReading {
    private let service: String

    init(service: String = ClaudeKeychain.credentialService) {
        self.service = service
    }

    func probe() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func readAccessToken() throws -> String? {
        guard let oauth = try readOAuthPayload() else { return nil }
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            // 条目在但 token 空：Claude Code 登录过期时会原地清空 token。
            throw CredentialReadError.invalidPayload
        }
        return accessToken
    }

    func planLabel() -> String? {
        guard let oauth = try? readOAuthPayload() else { return nil }
        let token = (try? readAccessToken()) ?? nil
        return Self.planLabel(oauthPayload: oauth, accessToken: token)
    }

    /// 套餐来源：存储原文 `claudeAiOauth.subscriptionType` 优先（登录过期
    /// token 被清空时 JWT 解不出，存储原文仍在）；缺失回落 JWT claim。
    static func planLabel(oauthPayload: [String: Any]?, accessToken: String?) -> String? {
        if let stored = oauthPayload?["subscriptionType"] as? String, !stored.isEmpty {
            return PlanLabelNormalizer.normalize(stored)
        }
        guard let accessToken,
              let payload = JWTPayloadDecoder.decodePayload(accessToken) else { return nil }
        return PlanLabelNormalizer.normalize(payload["subscriptionType"] as? String)
    }

    /// 解析条目 JSON 的 `claudeAiOauth` 对象；条目不存在 → nil；JSON 损坏 → 抛错。
    private func readOAuthPayload() throws -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw CredentialReadError.keychainUnavailable(status)
        }
        guard let data = item as? Data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CredentialReadError.invalidPayload
        }
        return root["claudeAiOauth"] as? [String: Any]
    }
}

/// 套餐名清洗：`max`→`Max`、`pro`→`Pro`、空/未知 → nil。
enum PlanLabelNormalizer {
    static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let known = ["free", "pro", "max", "team", "enterprise"]
        if known.contains(lower) {
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        if ["none", "unknown", "invalid"].contains(lower) { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
