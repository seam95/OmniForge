import Foundation

// MARK: - 解析纯函数

/// opencode Go usage API 归一化 — 纯函数。
///
/// 端点存在两代响应形状：现行 `{usage:{rolling:{percent,resetsAt}}}`（绝对
/// 时间）与早期规范 `顶层 rollingUsage:{usagePercent,resetInSec}`（相对秒）。
/// 解析时现行形状优先，解析不出回落早期形状；部分 payload 用 0–1 小数比例
/// 表示百分比，统一换算。
enum OpencodeGoParsing {
    /// 现行形状单窗（`usage.rolling` 等）：percent + resetsAt（也兼容
    /// usagePercent/usage_percent 与 resetInSec 相对秒）。
    static func window(_ usage: [String: Any]?) -> UsageWindow? {
        guard let usage else { return nil }
        let percent = UsageWindowParsing.numeric(usage["percent"])
            ?? UsageWindowParsing.numeric(usage["usagePercent"])
            ?? UsageWindowParsing.numeric(usage["usage_percent"])
        var resetAt: Date?
        if let resetInSec = UsageWindowParsing.numeric(usage["resetInSec"])
            ?? UsageWindowParsing.numeric(usage["reset_in_sec"]) {
            resetAt = Date().addingTimeInterval(resetInSec)
        } else {
            resetAt = UsageWindowParsing.parseResetDate(
                usage["resetsAt"] ?? usage["resets_at"] ?? usage["resetAt"] ?? usage["reset_at"]
            )
        }
        return window(percent: percent, resetAt: resetAt)
    }

    /// 早期形状单窗（顶层 `rollingUsage` 等）：usagePercent + resetInSec。
    static func legacyWindow(_ legacy: [String: Any]?) -> UsageWindow? {
        guard let legacy else { return nil }
        let percent = UsageWindowParsing.numeric(legacy["usagePercent"])
            ?? UsageWindowParsing.numeric(legacy["percent"])
        let resetInSec = UsageWindowParsing.numeric(legacy["resetInSec"])
            ?? UsageWindowParsing.numeric(legacy["reset_in_sec"])
        return window(
            percent: percent,
            resetAt: resetInSec.map { Date().addingTimeInterval($0) }
        )
    }

    /// 现行形状优先、解析不出（含字段不完整）回落早期形状。
    static func resolveWindow(modern: Any?, legacy: [String: Any]?) -> UsageWindow? {
        if let modernObject = modern as? [String: Any] {
            let hasSignal = UsageWindowParsing.numeric(modernObject["percent"]) != nil
                || UsageWindowParsing.numeric(modernObject["usagePercent"]) != nil
                || UsageWindowParsing.numeric(modernObject["usage_percent"]) != nil
                || UsageWindowParsing.numeric(modernObject["resetInSec"]) != nil
                || UsageWindowParsing.numeric(modernObject["reset_in_sec"]) != nil
                || modernObject["resetsAt"] != nil
                || modernObject["resets_at"] != nil
            if hasSignal, let window = window(modernObject) {
                return window
            }
        }
        return legacyWindow(legacy)
    }

    private static func window(percent: Double?, resetAt: Date?) -> UsageWindow? {
        guard var raw = percent else { return nil }
        // 0–1 小数比例 → 换算为百分比（部分 payload 的表示法）。
        if raw > 0, raw < 1 { raw *= 100 }
        return UsageWindow(
            usedPercent: min(max(raw, 0), 100),
            resetAt: resetAt,
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
        let slots: [(kind: LimitWindowKind, modern: Any?, legacyKey: String)] = [
            (.session, usage?["rolling"] ?? payload["rolling"], "rollingUsage"),
            (.weekly, usage?["weekly"] ?? payload["weekly"], "weeklyUsage"),
            (.monthly, usage?["monthly"] ?? payload["monthly"], "monthlyUsage"),
        ]
        for slot in slots {
            if let window = OpencodeGoParsing.resolveWindow(
                modern: slot.modern,
                legacy: payload[slot.legacyKey] as? [String: Any]
            ) {
                windows[slot.kind] = window
            }
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
