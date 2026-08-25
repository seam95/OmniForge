import Foundation

// MARK: - 解析纯函数

/// opencode Go usage API 归一化 — 纯函数。
enum OpencodeGoParsing {
    /// `usagePercent`（0–1 或 0–100）+ `resetInSec` → UsageWindow；缺值 → nil。
    static func window(_ usage: [String: Any]?) -> UsageWindow? {
        guard let usage,
              let rawPercent = (usage["usagePercent"] as? NSNumber)?.doubleValue ?? double(usage["usage_percent"]) else {
            return nil
        }
        let percent = clamp(rawPercent)
        let resetInSec = (usage["resetInSec"] as? NSNumber)?.doubleValue ?? double(usage["reset_in_sec"])
        let resetAt = resetInSec.flatMap { $0 >= 0 ? Date().addingTimeInterval($0) : nil }
        return UsageWindow(
            usedPercent: percent,
            resetAt: resetAt,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: nil
        )
    }

    static func clamp(_ value: Double) -> Double {
        // 0–1 小数按百分比放大（0.02 → 2%）；1 保持 1%。
        let scaled = value > 0 && value < 1 ? value * 100 : value
        return min(max(scaled, 0), 100)
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

// MARK: - Fetcher

/// opencode Go 限额（官方 API 档）：钥匙串存储 API Key（优先）/ `OPENCODE_GO_API_KEY`（环境变量兜底）→
/// `opencode.ai/zen/go/v1/usage` Bearer → rolling/weekly/monthly 三窗。
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
        if let rolling = OpencodeGoParsing.window(payload["rollingUsage"] as? [String: Any]) {
            windows[.session] = rolling
        }
        if let weekly = OpencodeGoParsing.window(payload["weeklyUsage"] as? [String: Any]) {
            windows[.weekly] = weekly
        }
        if let monthly = OpencodeGoParsing.window(payload["monthlyUsage"] as? [String: Any]) {
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