import Foundation

// MARK: - 解析纯函数

/// opencode Go usage API 归一化 — 纯函数。
enum OpencodeGoParsing {
    /// `percent`（0–100）+ `resetsAt` → UsageWindow；缺值 → nil。
    static func window(_ usage: [String: Any]?) -> UsageWindow? {
        guard let usage,
              let rawPercent = UsageWindowParsing.numeric(usage["percent"]) else {
            return nil
        }
        return UsageWindow(
            usedPercent: UsageWindowParsing.clampPercent(rawPercent) ?? 0,
            resetAt: UsageWindowParsing.parseResetDate(usage["resetsAt"]),
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: nil
        )
    }
}

// MARK: - Fetcher

/// opencode Go 限额（官方 API 档）：钥匙串存储 API Key（优先）/ `OPENCODE_GO_API_KEY`（环境变量兜底）→
/// `opencode.ai/zen/go/v1/usage` Bearer → `usage.rolling/weekly/monthly` 三窗。
///
/// 说明（范围收敛）：网页抓取与本地 DB 估算两档本期不接（SPEC §4.3 三级降级
/// 仅实现 API 档）；无 API key → `configured: false`，零网络请求。
final class OpencodeLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .opencode

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    var timeout: TimeInterval = 10
    private let session: URLSession
    private let keyStore: OpencodeAPIKeyStoring?
    private let environment: [String: String]

    init(
        session: URLSession = .shared,
        keyStore: OpencodeAPIKeyStoring? = OpencodeKeychainAPIKeyStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.session = session
        self.keyStore = keyStore
        self.environment = environment
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        let keychainKey = (try? keyStore?.readAPIKey())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey: String?
        if let keychainKey, !keychainKey.isEmpty {
            effectiveKey = keychainKey
        } else {
            effectiveKey = environment["OPENCODE_GO_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let apiKey = effectiveKey, !apiKey.isEmpty else {
            return nil
        }
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("OpenCode Go usage request failed")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LimitError.reauthRequired
        }
        guard http.statusCode == 200 else {
            throw LimitError.network("OpenCode Go usage API returned HTTP \(http.statusCode)")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("OpenCode Go usage API returned non-JSON")
        }

        var windows: [LimitWindowKind: UsageWindow] = [:]
        let usage = payload["usage"] as? [String: Any]
        if let rolling = OpencodeGoParsing.window(usage?["rolling"] as? [String: Any]) {
            windows[.session] = rolling
        }
        if let weekly = OpencodeGoParsing.window(usage?["weekly"] as? [String: Any]) {
            windows[.weekly] = weekly
        }
        if let monthly = OpencodeGoParsing.window(usage?["monthly"] as? [String: Any]) {
            windows[.monthly] = monthly
        }
        guard !windows.isEmpty else {
            return nil
        }
        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: nil,
            windows: windows,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }
}
