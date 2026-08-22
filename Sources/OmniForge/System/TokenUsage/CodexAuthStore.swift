import Foundation

// MARK: - 凭证包与读取边界

/// Codex 凭证包 — auth.json 的必要字段（参考 04/08；最小化：不触碰会话内容）。
struct CodexAuthBundle {
    var authURL: URL
    var accessToken: String
    var idToken: String?
    var refreshToken: String?
    var accountID: String?
    /// 命名空间声明的原始套餐名（如 "plus"）；可显示性由 `CodexPlanExtractor` 判定。
    var planType: String?
    /// auth.json 的 `last_refresh` ISO 字符串。
    var lastRefresh: String?
    /// 原始解析结果 — 刷新写回时做字段合并（保留 openid 等无关字段）。
    var raw: [String: Any]
}

/// 凭证文件未按预期结构组织（缺失 tokens.access_token 等）。
enum CodexAuthFileError: Error, Equatable {
    case invalidPayload
}

/// Codex 凭证读取边界（参考 04：探测与读秘密在同一文件读取完成，无 Keychain 授权需求）。
protocol CodexCredentialReading: AnyObject {
    /// auth.json 缺失 → nil（未配置）；存在但结构损坏 → throw（调用方降级未配置）。
    func readBundle() throws -> CodexAuthBundle?
}

/// `~/.codex/auth.json`（`CODEX_HOME` 可覆盖）— 明文 JSON 凭证。
final class CodexAuthFileCredentialReader: CodexCredentialReading {
    let authURL: URL

    /// 默认路径解析：`CODEX_HOME` 优先，否则 `~/.codex/auth.json`（参考 resolveCodexHome）。
    static func defaultAuthURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: String
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            base = override
        } else {
            base = homePath + "/.codex"
        }
        return URL(fileURLWithPath: base).appendingPathComponent("auth.json", isDirectory: false)
    }

    init(authURL: URL = CodexAuthFileCredentialReader.defaultAuthURL()) {
        self.authURL = authURL
    }

    func readBundle() throws -> CodexAuthBundle? {
        let data: Data
        do {
            data = try Data(contentsOf: authURL)
        } catch {
            return nil // 文件缺失/不可读 → 未配置
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexAuthFileError.invalidPayload
        }
        let idToken = tokens["id_token"] as? String
        let refreshToken = tokens["refresh_token"] as? String
        let rawAccountID = tokens["account_id"] as? String
        return CodexAuthBundle(
            authURL: authURL,
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            accountID: CodexPlanExtractor.accountID(
                fromAuthTokenRaw: rawAccountID,
                accessToken: accessToken,
                idToken: idToken
            ),
            planType: CodexPlanExtractor.rawPlan(accessToken: accessToken, idToken: idToken),
            lastRefresh: root["last_refresh"] as? String,
            raw: root
        )
    }
}

// MARK: - JWT 命名空间提取（参考 04 / subscriptions.js）

/// Codex JWT 的 ChatGPT 声明（access/id_token 的 `https://api.openai.com/auth` 命名空间）。
enum CodexPlanExtractor {
    static let authNamespace = "https://api.openai.com/auth"

    /// 原始套餐名（access 优先，id 兜底；均无命名空间 → nil）。
    static func rawPlan(accessToken: String?, idToken: String?) -> String? {
        let access = payloadClaim(accessToken)["chatgpt_plan_type"] as? String
        if let access, !access.isEmpty { return access }
        return payloadClaim(idToken)["chatgpt_plan_type"] as? String
    }

    /// 显示用套餐名：`free/none/unknown/invalid` 不可显示 → nil（参考 isDisplayablePlanType）。
    static func displayablePlan(accessToken: String?, idToken: String?) -> String? {
        guard let raw = rawPlan(accessToken: accessToken, idToken: idToken), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "free", "none", "unknown", "invalid": return nil
        default: return PlanLabelNormalizer.normalize(raw)
        }
    }

    /// 账号 id：auth.json 显式 `tokens.account_id` 优先，否则读 JWT `chatgpt_account_id`。
    static func accountID(fromAuthTokenRaw raw: String?, accessToken: String?, idToken: String?) -> String? {
        if let raw, !raw.isEmpty { return raw }
        let fromAccess = payloadClaim(accessToken)["chatgpt_account_id"] as? String
        if let fromAccess, !fromAccess.isEmpty { return fromAccess }
        let fromID = payloadClaim(idToken)["chatgpt_account_id"] as? String
        return (fromID?.isEmpty == false) ? fromID : nil
    }

    private static func payloadClaim(_ token: String?) -> [String: Any] {
        guard let token else { return [:] }
        guard let payload = JWTPayloadDecoder.decodePayload(token),
              let namespace = payload[authNamespace] as? [String: Any] else {
            return [:]
        }
        return namespace
    }
}

// MARK: - JWT 过期与「临期才刷」（参考 codex-token-refresh.js:14-36）

/// 令牌过期判定 — 纯函数。
enum CodexTokenFreshness {
    /// JWT 临期窗口：过期前 5 分钟内即视为需要刷新（对齐官方口径 ACCESS_TOKEN_REFRESH_WINDOW_MS）。
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    /// 无 exp 的透明令牌回退：last_refresh 超过 8 天视为过期（REFRESH_THRESHOLD_MS）。
    static let opaqueTokenMaxAge: TimeInterval = 8 * 24 * 60 * 60

    /// JWT payload 的 `exp`（unix 秒）→ Date；非 JWT / 无 exp → nil。
    static func expiration(of token: String?) -> Date? {
        guard let token, !token.isEmpty else { return nil }
        guard let payload = JWTPayloadDecoder.decodePayload(token) else { return nil }
        guard let exp = payload["exp"] as? NSNumber, exp.doubleValue.isFinite, exp.doubleValue > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// 「临期才刷」判定：有 exp 时看 5 分钟窗口；无 exp 回退 last_refresh 8 天（无需刷 → false）。
    static func isStale(accessToken: String?, lastRefresh: String?, now: Date) -> Bool {
        if let expiresAt = expiration(of: accessToken) {
            return expiresAt <= now.addingTimeInterval(accessTokenRefreshWindow)
        }
        guard let lastRefresh, !lastRefresh.isEmpty else { return true }
        let refreshedAt = ISO8601DateFormatter().date(from: lastRefresh)
        guard let refreshedAt else { return true }
        return now.timeIntervalSince(refreshedAt) > opaqueTokenMaxAge
    }
}

// MARK: - 原子写回（tmp + rename，0600）

/// 刷新后的 auth.json 写回（参考 persistRefreshedAuth；隐私红线：只写凭证字段）。
enum CodexAuthPersistence {
    /// 兼容取数器注入签名的入口（默认参数包装）。
    static func persistDefault(
        _ bundle: CodexAuthBundle,
        _ tokens: CodexRefreshedTokens,
        _ now: Date
    ) throws -> CodexAuthBundle {
        try persist(newTokens: tokens, into: bundle, now: now)
    }

    /// 合并新令牌并原子写回：tmp + rename，0600；`last_refresh` 更新；无关字段保留。
    ///
    /// 原子性关键：写临时文件 → 移动到目标路径（进程中途被杀也不会写坏 auth.json，
    /// 否则用户会被迫重新 `codex login`）。
    static func persist(
        newTokens: CodexRefreshedTokens,
        into bundle: CodexAuthBundle,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> CodexAuthBundle {
        var root = bundle.raw
        let oldTokens = (root["tokens"] as? [String: Any]) ?? [:]
        var tokens = oldTokens
        tokens["access_token"] = newTokens.accessToken
        tokens["refresh_token"] = newTokens.refreshToken ?? oldTokens["refresh_token"]
        tokens["id_token"] = newTokens.idToken ?? oldTokens["id_token"]
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: now)

        let authURL = bundle.authURL
        let temp = authURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try data.write(to: temp, options: [.atomic])
            if fileManager.fileExists(atPath: authURL.path) {
                _ = try fileManager.replaceItemAt(authURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: authURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }

        return CodexAuthBundle(
            authURL: authURL,
            accessToken: newTokens.accessToken,
            idToken: newTokens.idToken ?? bundle.idToken,
            refreshToken: newTokens.refreshToken ?? bundle.refreshToken,
            accountID: bundle.accountID,
            planType: bundle.planType,
            lastRefresh: root["last_refresh"] as? String,
            raw: root
        )
    }
}
