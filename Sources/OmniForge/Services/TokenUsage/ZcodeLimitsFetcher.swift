import CryptoKit
import Foundation

// MARK: - 解析纯函数

/// zcode billing/balance 归一化 — 纯函数。
enum ZcodeLimitsParsing {
    /// `data.balances[]` → 按 total 降序的窗口数组（limit/used/remaining/unit）。
    static func windows(from body: [String: Any]?) -> [UsageWindow] {
        let data = body?["data"] as? [String: Any]
        let balances = data?["balances"] as? [[String: Any]] ?? []
        let buckets = balances.compactMap { bucket -> UsageWindow? in
            let total = number(bucket["total_units"])
            let used = number(bucket["used_units"])
            let remaining = number(bucket["remaining_units"])
            guard let total, total > 0, let used else { return nil }
            let resetAt = (number(bucket["period_end"]) ?? number(bucket["expires_at"]))
                .flatMap { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) }
            return UsageWindow(
                usedPercent: min(max(used / total * 100, 0), 100),
                resetAt: resetAt,
                limit: total,
                used: used,
                remaining: remaining,
                unit: "credits",
                windowSeconds: nil
            )
        }
        return buckets.sorted { ($0.limit ?? 0) > ($1.limit ?? 0) }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

// MARK: - Fetcher

/// zcode 限额：`~/.zcode/v2/credentials.json` 的 `zcodejwttoken`（enc:v1 AES-256-GCM
/// 解密或明文）→ `zcode.z.ai/api/v1/zcode-plan/billing/balance` → GLM 额度桶。
///
/// 解密失败/凭证缺失 → `configured: false`（fail-soft，SPEC R5：TokenTracker 私有
/// 实现可能漂移，绝不崩溃）。
final class ZcodeLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .zcode

    static let billingBaseURL = "https://zcode.z.ai/api/v1/zcode-plan"

    var timeout: TimeInterval = 10
    /// 测试注入：覆盖 zcode home 目录（默认 `~/.zcode`）。
    var homeOverride: URL?

    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 1. 凭证：credentials.json 的 zcodejwttoken（需 active_provider 为 zai/bigmodel）。
        let home = homeOverride ?? ZcodeUsageCollector.defaultDatabaseURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let credentialsURL = home.appendingPathComponent("v2/credentials.json")
        guard let jwt = loadJWT(at: credentialsURL, home: home) else {
            return nil
        }

        // 2. billing/balance。
        var request = URLRequest(url: URL(string: Self.billingBaseURL + "/billing/balance")!)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("ZCode balance request failed")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LimitError.reauthRequired
        }
        guard http.statusCode == 200 else {
            throw LimitError.network("ZCode balance API returned HTTP \(http.statusCode)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("ZCode balance API returned non-JSON")
        }

        // 3. 窗口：主额度桶 → .credits；次/三桶 → labeled。
        let windows = ZcodeLimitsParsing.windows(from: payload)
        guard !windows.isEmpty else { return nil }
        var primary: [LimitWindowKind: UsageWindow] = [:]
        var labeled: [LabeledUsageWindow] = []
        if let first = windows.first {
            primary[.credits] = first
        }
        for (index, window) in windows.enumerated() where index > 0 {
            let label = index == 1 ? "secondary" : "tertiary"
            labeled.append(LabeledUsageWindow(label: label, window: window))
        }
        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: nil,
            windows: primary,
            labeledWindows: labeled,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }

    // MARK: - 凭证读取与解密

    private func loadJWT(at credentialsURL: URL, home: URL) -> String? {
        guard let data = try? Data(contentsOf: credentialsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let active = decrypted(parsed["oauth:active_provider"], home: home),
              active == "zai" || active == "bigmodel" else {
            return nil
        }
        guard let jwt = decrypted(parsed["zcodejwttoken"], home: home), !jwt.isEmpty else {
            return nil
        }
        return jwt
    }

    /// enc:v1 解密（AES-256-GCM，密钥 = sha256(secret)）或明文直通；失败 → nil。
    private func decrypted(_ value: Any?, home: URL) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        guard value.hasPrefix("enc:v1:") else { return value }
        let parts = value.dropFirst("enc:v1:".count).split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let iv = Data(base64Encoded: String(parts[0]), options: .ignoreUnknownCharacters),
              let tag = Data(base64Encoded: String(parts[1]), options: .ignoreUnknownCharacters),
              let encrypted = Data(base64Encoded: String(parts[2]), options: .ignoreUnknownCharacters) else {
            return nil
        }
        let secret = "zcode-credential-fallback:\(hostPlatform):\(home.path):\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let box = try? AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: encrypted,
            tag: tag
        ), let decrypted = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        let string = String(data: decrypted, encoding: .utf8) ?? ""
        return string.isEmpty ? nil : string
    }

    private var hostPlatform: String {
        #if os(macOS)
        "darwin"
        #else
        "linux"
        #endif
    }
}