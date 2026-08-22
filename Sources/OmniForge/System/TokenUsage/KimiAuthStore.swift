import Foundation

// MARK: - 凭证包与读取边界

/// Kimi 凭证包 — credentials/kimi-code.json 的必要字段（参考 08/usage-limits.js:695-735）。
struct KimiAuthBundle {
    var credsURL: URL
    var accessToken: String
    var refreshToken: String?
    /// `expires_at`（epoch 秒）→ Date；缺失 → nil。
    var expiresAt: Date?
    var scope: String?
    var tokenType: String?
    /// 原始解析结果 — 刷新写回时做字段合并。
    var raw: [String: Any]
}

/// 凭证文件未按预期结构组织（缺失 access_token 等）。
enum KimiAuthFileError: Error, Equatable {
    case invalidPayload
}

/// Kimi 凭证读取边界（明文凭证；Kimi Code 优先、旧版回退）。
protocol KimiCredentialReading: AnyObject {
    /// kimi-code.json 缺失 → nil（未配置）；存在但结构损坏 → throw（调用方降级未配置）。
    func readBundle() throws -> KimiAuthBundle?
}

/// kimi-code.json 读取器 — home 解析 + 存在性探测（参考 resolveKimiHome：KIMI_HOME 显式优先，
/// 否则 Kimi Code 持有登录则用 `~/.kimi-code`，回退旧版 `~/.kimi`）。
final class KimiAuthFileCredentialReader: KimiCredentialReading {
    let credsURL: URL

    /// Kimi home 解析（纯函数，可单测）：
    /// `KIMI_HOME` / `KIMI_CODE_HOME` 显式覆盖 → 直接返回；
    /// 否则 `~/.kimi-code` 持有有效 access_token → 该 home；
    /// 否则回退 `~/.kimi`（旧版 kimi-cli）。
    static func resolveKimiHome(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["KIMI_HOME"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let base = URL(fileURLWithPath: homePath)
        if let explicitCode = environment["KIMI_CODE_HOME"], !explicitCode.isEmpty {
            // 用户显式指定 → 尊重（即使该目录暂无凭证）
            return URL(fileURLWithPath: explicitCode)
        }
        let codeHome = base.appendingPathComponent(".kimi-code", isDirectory: true)
        let codeCreds = credentialURL(home: codeHome)
        if let data = try? Data(contentsOf: codeCreds),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           !(root["access_token"] as? String ?? "").isEmpty {
            return codeHome
        }
        return base.appendingPathComponent(".kimi", isDirectory: true)
    }

    static func credentialURL(home: URL) -> URL {
        home.appendingPathComponent("credentials/kimi-code.json", isDirectory: false)
    }

    /// 默认 `resolveKimiHome()/credentials/kimi-code.json`。
    static func defaultCredsURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        credentialURL(home: resolveKimiHome(homePath: homePath, environment: environment))
    }

    init(credsURL: URL = KimiAuthFileCredentialReader.defaultCredsURL()) {
        self.credsURL = credsURL
    }

    func readBundle() throws -> KimiAuthBundle? {
        let data: Data
        do {
            data = try Data(contentsOf: credsURL)
        } catch {
            return nil // 文件缺失/不可读 → 未配置
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = root["access_token"] as? String,
              !accessToken.isEmpty else {
            throw KimiAuthFileError.invalidPayload
        }
        let expiresAtSeconds = (root["expires_at"] as? NSNumber)?.doubleValue
        return KimiAuthBundle(
            credsURL: credsURL,
            accessToken: accessToken,
            refreshToken: root["refresh_token"] as? String,
            expiresAt: expiresAtSeconds.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            scope: root["scope"] as? String,
            tokenType: root["token_type"] as? String,
            raw: root
        )
    }
}

// MARK: - expires_at 临期判定（参考 kimiCredentialsExpired）

/// Kimi token 过期判定 — 纯函数。
enum KimiTokenFreshness {
    /// 「临期才刷」：`expires_at * 1000 <= now + 30_000`（30 秒容差，对齐参考实现）。
    /// 无 expires_at → 不视为过期（由 401 兜底）。
    static func isStale(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(30)
    }
}

// MARK: - 原子写回（tmp + rename，0600）

/// 刷新后的 kimi-code.json 写回（参考 saveKimiCredentials；隐私红线：只写凭证字段）。
enum KimiAuthPersistence {
    /// 兼容取数器注入签名的入口（默认参数包装）。
    static func persistDefault(
        _ bundle: KimiAuthBundle,
        _ tokens: KimiRefreshedTokens,
        _ now: Date
    ) throws -> KimiAuthBundle {
        try persist(newTokens: tokens, into: bundle, now: now)
    }

    /// 合并新令牌并原子写回：tmp + rename，0600；`expires_at` 更新；无关字段保留。
    ///
    /// 原子性关键：写临时文件 → 移动到目标路径（进程中途被杀也不会写坏凭证文件）。
    static func persist(
        newTokens: KimiRefreshedTokens,
        into bundle: KimiAuthBundle,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> KimiAuthBundle {
        var root = bundle.raw
        root["access_token"] = newTokens.accessToken
        root["refresh_token"] = newTokens.refreshToken ?? bundle.refreshToken ?? ""
        let expiresIn = (newTokens.expiresIn?.isFinite == true && newTokens.expiresIn! > 0) ? newTokens.expiresIn! : 900
        root["expires_at"] = now.timeIntervalSince1970 + expiresIn
        root["scope"] = newTokens.scope ?? "kimi-code"
        root["token_type"] = newTokens.tokenType ?? "Bearer"
        root["expires_in"] = expiresIn

        let credsURL = bundle.credsURL
        let credsDirectory = credsURL.deletingLastPathComponent()
        let temp = credsDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            try fileManager.createDirectory(at: credsDirectory, withIntermediateDirectories: true)
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

        return KimiAuthBundle(
            credsURL: credsURL,
            accessToken: newTokens.accessToken,
            refreshToken: newTokens.refreshToken ?? bundle.refreshToken,
            expiresAt: Date(timeIntervalSince1970: now.timeIntervalSince1970 + expiresIn),
            scope: root["scope"] as? String,
            tokenType: root["token_type"] as? String,
            raw: root
        )
    }
}
