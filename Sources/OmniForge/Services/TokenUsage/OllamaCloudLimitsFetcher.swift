import Foundation

// MARK: - 取数边界

/// Ollama Cloud 余额取数边界 — 签名与 `ProviderAPIClient.getJSON` 一致，便于测试替身。
protocol OllamaCloudBalanceFetching: AnyObject {
    func getJSON(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> [String: Any]
}

/// 生产实现复用共享 HTTP 客户端（401/403 → reauth、429 → rateLimited、15s 超时）。
/// conformance 放在本文件：不改动 ProviderAPIClient 本体。
extension ProviderAPIClient: OllamaCloudBalanceFetching {}

// MARK: - 解析纯函数

/// Ollama Cloud `/api/balance` 归一化 — 纯函数（参考 SPEC §3.2 / §3.3）。
///
/// `included` 官方为 oneOf 两形态：新版美元余额（`balance_usd`/`allowance_usd`/`period`）
/// 与旧版百分比配额（`session`/`weekly` 各含 `remaining_percent` + `resets_at`）；
/// `purchased.balance_usd` 为充值余额，独立于形态解析。社区工具观测到的变体
/// （`windows.monthly.used_pct`、`credits.included.spent_usd`）做宽松兜底。
enum OllamaCloudBalanceParsing {
    /// 宽松数值：数字或数字字符串 → Double。
    private static func numeric(_ raw: Any?) -> Double? {
        UsageWindowParsing.numeric(raw)
    }

    /// 宽松时间：秒 / 毫秒 / ISO8601 / Date 统一 → Date。
    private static func date(_ raw: Any?) -> Date? {
        UsageWindowParsing.parseResetDate(raw)
    }

    /// 解析 balance 响应 → 限额快照；解析不出任何窗口 → nil（调用方降级未配置口径）。
    static func parse(
        _ payload: [String: Any],
        provider: TokenUsageProvider = .ollamaCloud,
        capturedAt: Date = Date()
    ) -> ProviderUsageLimits? {
        var windows = parseWindows(payload)

        // 社区变体兜底：credits.included.spent_usd → 补充 credits 窗口已用值（不作为主判定信号）。
        if windows[.credits] != nil {
            let spent = numeric(
                ((payload["credits"] as? [String: Any])?["included"] as? [String: Any])?["spent_usd"]
            )
            if let spent, windows[.credits]?.used == nil {
                windows[.credits]?.used = max(spent, 0)
            }
        }

        guard !windows.isEmpty else { return nil }
        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: nil,
            windows: windows,
            confidence: .official,
            capturedAt: capturedAt,
            stale: false,
            issue: nil
        )
    }

    /// 响应 → 窗口集合（形态 A credits 总池 / 形态 B session+weekly / 社区 monthly 变体）。
    static func parseWindows(_ payload: [String: Any]) -> [LimitWindowKind: UsageWindow] {
        let included = payload["included"] as? [String: Any]
        let purchasedBalance = numeric(
            (payload["purchased"] as? [String: Any])?["balance_usd"]
        )

        var windows: [LimitWindowKind: UsageWindow] = [:]

        // 形态 A：新版美元余额 → credits 总池（订阅额度 + 充值余额合并，SPEC §3.2）。
        if let credits = modernCreditsWindow(included: included, purchasedBalance: purchasedBalance) {
            windows[.credits] = credits
        }

        // 形态 B：旧版百分比配额（remaining_percent 为剩余，换算已用）。
        if let session = legacyWindow(included?["session"]) {
            windows[.session] = session
        }
        if let weekly = legacyWindow(included?["weekly"]) {
            windows[.weekly] = weekly
        }

        // 社区变体：windows.monthly.used_pct → 月度窗口。
        if let monthly = communityMonthlyWindow(payload["windows"]) {
            windows[.monthly] = monthly
        }

        // 仅充值余额（无 included 任何形态）：credits 只展示金额，无上限与百分比。
        if windows.isEmpty, let purchasedBalance, purchasedBalance > 0 {
            windows[.credits] = UsageWindow(
                usedPercent: 0,
                resetAt: nil,
                limit: nil,
                used: nil,
                remaining: purchasedBalance,
                unit: "USD"
            )
        }

        return windows
    }

    /// 形态 A：included{balance_usd, allowance_usd, period} + purchased → credits 总池。
    /// - limit = allowance + purchased；remaining = balance + purchased；
    ///   usedPercent = (limit − remaining) / limit（推导不出时置 0，满条 = 余额全部可用）。
    private static func modernCreditsWindow(
        included: [String: Any]?,
        purchasedBalance: Double?
    ) -> UsageWindow? {
        let balance = numeric(included?["balance_usd"])
        let allowance = numeric(included?["allowance_usd"])
        // 形态信号：余额或额度任一存在才算新版形态（避免误吞形态 B / 空响应）。
        guard balance != nil || allowance != nil else { return nil }

        let purchased = purchasedBalance ?? 0
        let remaining = (balance ?? 0) + purchased
        let totalLimit = (allowance ?? 0) + purchased

        var usedPercent = 0.0
        var used: Double?
        if totalLimit > 0 {
            used = max(totalLimit - remaining, 0)
            usedPercent = min(max(used! / totalLimit * 100, 0), 100)
        }

        let period = included?["period"] as? [String: Any]
        return UsageWindow(
            usedPercent: usedPercent,
            resetAt: date(period?["until"]),
            limit: totalLimit > 0 ? totalLimit : nil,
            used: used,
            remaining: remaining,
            unit: "USD"
        )
    }

    /// 形态 B 单窗：{remaining_percent(0-100 剩余), resets_at} → 已用百分比口径。
    private static func legacyWindow(_ raw: Any?) -> UsageWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let remainingPercent = numeric(dict["remaining_percent"])
        guard let remainingPercent else { return nil }
        let clampedRemaining = min(max(remainingPercent, 0), 100)
        return UsageWindow(
            usedPercent: 100 - clampedRemaining,
            resetAt: date(dict["resets_at"]),
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil
        )
    }

    /// 社区变体单窗：windows.monthly{used_pct, reset_at?}（ollama-cloud-usage 观测口径）。
    private static func communityMonthlyWindow(_ raw: Any?) -> UsageWindow? {
        guard let dict = (raw as? [String: Any])?["monthly"] as? [String: Any] else { return nil }
        let usedPct = numeric(dict["used_pct"]) ?? numeric(dict["used_percent"])
        guard let usedPct else { return nil }
        return UsageWindow(
            usedPercent: min(max(usedPct, 0), 100),
            resetAt: date(dict["reset_at"] ?? dict["resets_at"]),
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil
        )
    }
}

// MARK: - 取数器

/// Ollama Cloud 余额取数器：钥匙串 API Key（优先）/ `OLLAMA_API_KEY`（环境变量兜底）→
/// `ollama.com/api/balance` Bearer → 双形态解析（美元总池 / 百分比配额）。
///
/// 无 Key → nil（未配置，零网络请求）；HTTP 错误映射由共享 `ProviderAPIClient` 统一处理。
final class OllamaCloudLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .ollamaCloud

    static let balanceURL = URL(string: "https://ollama.com/api/balance")!
    static let environmentKeyName = "OLLAMA_API_KEY"

    private let keyStore: OllamaCloudAPIKeyStoring?
    private let client: OllamaCloudBalanceFetching
    private let environment: [String: String]
    private let now: () -> Date

    init(
        keyStore: OllamaCloudAPIKeyStoring? = OllamaCloudKeychainAPIKeyStore(),
        client: OllamaCloudBalanceFetching = ProviderAPIClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = { Date() }
    ) {
        self.keyStore = keyStore
        self.client = client
        self.environment = environment
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        guard let apiKey = resolveAPIKey(), !apiKey.isEmpty else {
            return nil
        }

        let payload = try await client.getJSON(
            url: Self.balanceURL,
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
            timeout: ProviderAPIClient.defaultRequestTimeout
        )
        return OllamaCloudBalanceParsing.parse(payload, provider: provider, capturedAt: now())
    }

    /// 凭证解析：钥匙串优先，环境变量兜底（对齐 opencode 模式）。
    private func resolveAPIKey() -> String? {
        let keychainKey = (try? keyStore?.readAPIKey())?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keychainKey, !keychainKey.isEmpty {
            return keychainKey
        }
        return environment[Self.environmentKeyName]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
