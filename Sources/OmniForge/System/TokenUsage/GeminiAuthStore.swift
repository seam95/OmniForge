import Foundation

// MARK: - 凭证包与读取边界

/// Gemini 凭证包 — oauth_creds.json 的必要字段（参考 08/usage-limits.js:895-932；最小化）。
struct GeminiAuthBundle {
    var credsURL: URL
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    /// `expiry_date`（epoch 毫秒）→ Date；缺失 → nil（参考口径：缺失不触发刷新，由 401 兜底）。
    var expiryDate: Date?
    /// 原始解析结果 — 刷新写回时做字段合并（保留 theme 等无关字段）。
    var raw: [String: Any]
}

/// 凭证文件未按预期结构组织（缺失 access_token 等）。
enum GeminiAuthFileError: Error, Equatable {
    case invalidPayload
}

/// Gemini 凭证读取边界（明文凭证，探测与读秘密一次性完成，无 Keychain 授权需求）。
protocol GeminiCredentialReading: AnyObject {
    /// oauth_creds.json 缺失 → nil（未配置）；存在但结构损坏 → throw（调用方降级未配置）。
    func readBundle() throws -> GeminiAuthBundle?
}

/// `~/.gemini/oauth_creds.json`（`GEMINI_HOME` 可覆盖）— 明文 JSON 凭证。
final class GeminiAuthFileCredentialReader: GeminiCredentialReading {
    let credsURL: URL

    /// 默认路径解析：`GEMINI_HOME` 优先，否则 `~/.gemini/oauth_creds.json`（参考 resolveGeminiHome）。
    static func defaultCredsURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: String
        if let override = environment["GEMINI_HOME"], !override.isEmpty {
            base = override
        } else {
            base = homePath + "/.gemini"
        }
        return URL(fileURLWithPath: base).appendingPathComponent("oauth_creds.json", isDirectory: false)
    }

    init(credsURL: URL = GeminiAuthFileCredentialReader.defaultCredsURL()) {
        self.credsURL = credsURL
    }

    func readBundle() throws -> GeminiAuthBundle? {
        let data: Data
        do {
            data = try Data(contentsOf: credsURL)
        } catch {
            return nil // 文件缺失/不可读 → 未配置
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = root["access_token"] as? String,
              !accessToken.isEmpty else {
            throw GeminiAuthFileError.invalidPayload
        }
        let expiryMilliseconds = (root["expiry_date"] as? NSNumber)?.doubleValue
        return GeminiAuthBundle(
            credsURL: credsURL,
            accessToken: accessToken,
            refreshToken: root["refresh_token"] as? String,
            idToken: root["id_token"] as? String,
            expiryDate: expiryMilliseconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil },
            raw: root
        )
    }
}

// MARK: - expiry_date 临期判定（参考 refreshGeminiAccessToken 触发条件）

/// Gemini token 过期判定 — 纯函数。
enum GeminiTokenFreshness {
    /// 「临期才刷」：expiry_date 已过（参考口径：`expiry < Date.now() && refresh_token`）。
    /// 无 expiry_date → 不视为过期（令牌是否有效由 401 兜底），避免频繁无谓刷新。
    static func isStale(expiryDate: Date?, now: Date) -> Bool {
        guard let expiryDate else { return false }
        return expiryDate <= now
    }
}

// MARK: - 原子写回（tmp + rename，0600）

/// 刷新后的 oauth_creds.json 写回（参考 persistRefreshedAuth 的参考；隐私红线：只写凭证字段）。
enum GeminiAuthPersistence {
    /// 兼容取数器注入签名的入口（默认参数包装）。
    static func persistDefault(
        _ bundle: GeminiAuthBundle,
        _ tokens: GeminiRefreshedTokens,
        _ now: Date
    ) throws -> GeminiAuthBundle {
        try persist(newTokens: tokens, into: bundle, now: now)
    }

    /// 合并新令牌并原子写回：tmp + rename，0600；`expiry_date` 更新；无关字段保留。
    ///
    /// 原子性关键：写临时文件 → 移动到目标路径（进程中途被杀也不会写坏凭证文件）。
    static func persist(
        newTokens: GeminiRefreshedTokens,
        into bundle: GeminiAuthBundle,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> GeminiAuthBundle {
        var root = bundle.raw
        root["access_token"] = newTokens.accessToken
        if let idToken = newTokens.idToken {
            root["id_token"] = idToken
        }
        if let expiresIn = newTokens.expiresIn, expiresIn.isFinite {
            root["expiry_date"] = (now.timeIntervalSince1970 + expiresIn) * 1000
        }

        let credsURL = bundle.credsURL
        let temp = credsURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try data.write(to: temp, options: [.atomic])
            if fileManager.fileExists(atPath: credsURL.path) {
                _ = try fileManager.replaceItemAt(credsURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: credsURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsURL.path)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }

        return GeminiAuthBundle(
            credsURL: credsURL,
            accessToken: newTokens.accessToken,
            refreshToken: bundle.refreshToken,
            idToken: newTokens.idToken ?? bundle.idToken,
            expiryDate: (root["expiry_date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
            raw: root
        )
    }
}
