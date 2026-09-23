import Foundation

// MARK: - 解析纯函数

enum StepfunPlanParsing {
    /// 兼容 Double、Int 与数字字符串（如 API 返回 "400000000" 或 1）。
    static func flexibleDouble(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let i64 = raw as? Int64 { return Double(i64) }
        if let s = raw as? String, let d = Double(s) { return d }
        return nil
    }

    /// 兼容秒级时间戳（Int64、Int、Double 或字符串如 "1777528800"）。
    static func flexibleDate(_ raw: Any?) -> Date? {
        var seconds: TimeInterval?
        if let i = raw as? Int64 {
            seconds = TimeInterval(i)
        } else if let i = raw as? Int {
            seconds = TimeInterval(i)
        } else if let d = raw as? Double {
            seconds = d
        } else if let s = raw as? String, let parsed = Double(s) {
            seconds = parsed
        }
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 判定是否为 Credit 额度池型套餐（Token Plan）。
    /// 规则：无有效滑动窗口，且具有 Credit 额度池字段，或 plan_family 为 2。
    static func isCreditPlan(payload: [String: Any]) -> Bool {
        let fiveHourReset = flexibleDate(payload["five_hour_usage_reset_time"])
        let weeklyReset = flexibleDate(payload["weekly_usage_reset_time"])
        let hasLiveWindow = (fiveHourReset != nil) || (weeklyReset != nil)
        if hasLiveWindow {
            return false
        }

        let creditObj = payload["plan_credit_rate_limit"] as? [String: Any]
        let hasCreditPool = creditObj?["subscription_credit_left_rate"] != nil
            || creditObj?["topup_credit_left_rate"] != nil
            || !((creditObj?["credit_buckets"] as? [[String: Any]])?.isEmpty ?? true)
        if hasCreditPool {
            return true
        }

        let planFamily = flexibleDouble(payload["plan_family"])
        return planFamily == 2.0
    }

    /// 解析 StepFun 响应，组装为 ProviderUsageLimits。
    static func parseLimits(
        rateLimitPayload: [String: Any],
        planStatusPayload: [String: Any]? = nil,
        provider: TokenUsageProvider = .stepfun,
        capturedAt: Date = Date()
    ) -> ProviderUsageLimits? {
        var windows: [LimitWindowKind: UsageWindow] = [:]

        // 解析套餐名称
        var planLabel: String?
        if let planStatus = planStatusPayload {
            let subscription = planStatus["subscription"] as? [String: Any]
            if let name = subscription?["name"] as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    planLabel = trimmed
                }
            }
        }

        if isCreditPlan(payload: rateLimitPayload) {
            // Credit 额度池型（Token Plan）
            let creditObj = rateLimitPayload["plan_credit_rate_limit"] as? [String: Any]
            var calculatedLeftRate: Double?
            var totalLimit: Double?
            var residualLimit: Double?
            var nextResetAt: Date?

            if let buckets = creditObj?["credit_buckets"] as? [[String: Any]], !buckets.isEmpty {
                var sumTotal: Double = 0
                var sumResidual: Double = 0
                var hasValidBucket = false

                for bucket in buckets {
                    guard let total = flexibleDouble(bucket["credit_total"]),
                          let residual = flexibleDouble(bucket["credit_residual"]),
                          total > 0, residual >= 0 else { continue }
                    sumTotal += total
                    sumResidual += residual
                    hasValidBucket = true

                    if let reset = flexibleDate(bucket["next_reset_at"]) ?? flexibleDate(bucket["expire_at"]) {
                        if nextResetAt == nil || reset < nextResetAt! {
                            nextResetAt = reset
                        }
                    }
                }

                if hasValidBucket, sumTotal > 0 {
                    calculatedLeftRate = min(max(sumResidual / sumTotal, 0), 1)
                    totalLimit = sumTotal
                    residualLimit = sumResidual
                }
            }

            if calculatedLeftRate == nil {
                // 回退读取单独的 subscription_credit_left_rate 或 topup_credit_left_rate
                let subRate = flexibleDouble(creditObj?["subscription_credit_left_rate"])
                let topupRate = flexibleDouble(creditObj?["topup_credit_left_rate"])
                calculatedLeftRate = subRate ?? topupRate
            }

            if nextResetAt == nil {
                nextResetAt = flexibleDate(creditObj?["subscription_credit_reset_time"])
            }

            if let leftRate = calculatedLeftRate {
                let clampedRate = min(max(leftRate, 0), 1)
                let usedPercent = min(max((1.0 - clampedRate) * 100, 0), 100)
                let usedVal = (totalLimit != nil && residualLimit != nil) ? (totalLimit! - residualLimit!) : nil
                windows[.credits] = UsageWindow(
                    usedPercent: usedPercent,
                    resetAt: nextResetAt,
                    limit: totalLimit,
                    used: usedVal,
                    remaining: residualLimit,
                    unit: "Credit"
                )
            }
        } else {
            // 滑动窗口型（旧版 Coding Plan）
            if let fiveHourLeft = flexibleDouble(rateLimitPayload["five_hour_usage_left_rate"]) {
                let clampedRate = min(max(fiveHourLeft, 0), 1)
                let usedPercent = min(max((1.0 - clampedRate) * 100, 0), 100)
                let resetAt = flexibleDate(rateLimitPayload["five_hour_usage_reset_time"])
                windows[.session] = UsageWindow(
                    usedPercent: usedPercent,
                    resetAt: resetAt,
                    windowSeconds: 18000
                )
            }

            if let weeklyLeft = flexibleDouble(rateLimitPayload["weekly_usage_left_rate"]) {
                let clampedRate = min(max(weeklyLeft, 0), 1)
                let usedPercent = min(max((1.0 - clampedRate) * 100, 0), 100)
                let resetAt = flexibleDate(rateLimitPayload["weekly_usage_reset_time"])
                windows[.weekly] = UsageWindow(
                    usedPercent: usedPercent,
                    resetAt: resetAt,
                    windowSeconds: 604800
                )
            }
        }

        guard !windows.isEmpty else {
            return nil
        }

        return ProviderUsageLimits(
            provider: provider,
            configured: true,
            subscriptionStatus: .active,
            planLabel: planLabel,
            windows: windows,
            confidence: .official,
            capturedAt: capturedAt,
            stale: false,
            issue: nil
        )
    }
}

// MARK: - 取数器

final class StepfunLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .stepfun

    private let keyStore: StepfunTokenStoring?
    private let client: StepfunWebAPIFetching
    private let environment: [String: String]
    private let now: () -> Date

    init(
        keyStore: StepfunTokenStoring? = StepfunKeychainStore(),
        client: StepfunWebAPIFetching = StepfunWebAPIClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = { Date() }
    ) {
        self.keyStore = keyStore
        self.client = client
        self.environment = environment
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        let keychainToken = (try? keyStore?.readToken())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken: String?
        if let keychainToken, !keychainToken.isEmpty {
            effectiveToken = keychainToken
        } else {
            effectiveToken = environment["STEPFUN_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let token = effectiveToken, !token.isEmpty else {
            return nil
        }

        let rateLimitPayload = try await client.queryRateLimit(token: token)
        let planStatusPayload = try? await client.getPlanStatus(token: token)

        return StepfunPlanParsing.parseLimits(
            rateLimitPayload: rateLimitPayload,
            planStatusPayload: planStatusPayload,
            provider: provider,
            capturedAt: now()
        )
    }
}
