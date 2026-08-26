import Foundation

// MARK: - usage-summary 响应解码（参考 usage-limits.js normalizeCursorUsageSummary）

/// Cursor usage-summary 解码 — 纯函数，独立可测。
///
/// 窗口口径：网页 API 只给「计费周期」一个主窗（计划总用量百分比），映射为 `.monthly`；
/// `billingCycleEnd` 为 reset、`billingCycleEnd - billingCycleStart` 秒数为窗口秒数。
/// 百分比优先级：
/// ① `totalPercentUsed`；② Auto/API 车道均值 → API → Auto；③ plan used/limit cents 反推；
/// ④ individualUsage.onDemand；⑤ teamUsage.onDemand；⑥ plan 为 0 时取各车道正数；
/// ⑦ team/enterprise 时优先团队池。任何变体 → 无窗口（降级不崩）。
enum CursorUsageSummaryDecoder {
    static func decode(_ object: [String: Any]) -> [LimitWindowKind: UsageWindow] {
        guard let cycle = billingCycle(from: object) else { return [:] }
        let individual = object["individualUsage"] as? [String: Any]
        let teamUsage = object["teamUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any] ?? [:]
        let indOnDemand = individual?["onDemand"] as? [String: Any] ?? [:]
        let teamOnDemand = teamUsage?["onDemand"] as? [String: Any] ?? [:]
        let membershipType = object["membershipType"] as? String ?? ""
        let limitType = object["limitType"] as? String ?? ""

        let autoPercent = percent(plan["autoPercentUsed"])
        let apiPercent = percent(plan["apiPercentUsed"])
        var planPercent = percent(plan["totalPercentUsed"])
        if planPercent == nil {
            if let autoPercent, let apiPercent {
                planPercent = clampPercent((autoPercent + apiPercent) / 2)
            } else if let apiPercent {
                planPercent = apiPercent
            } else if let autoPercent {
                planPercent = autoPercent
            } else {
                planPercent = centsPercent(plan["used"], limit: plan["limit"])
            }
        }
        if planPercent == nil {
            planPercent = centsPercent(indOnDemand["used"], limit: indOnDemand["limit"])
        }
        if planPercent == nil {
            planPercent = centsPercent(teamOnDemand["used"], limit: teamOnDemand["limit"])
        }
        // plan 显示 0% 但车道有正数 → 修正（enterprise/team 常见）。
        if planPercent == 0 {
            if let ind = centsPercent(indOnDemand["used"], limit: indOnDemand["limit"]), ind > 0 {
                planPercent = ind
            } else if let team = centsPercent(teamOnDemand["used"], limit: teamOnDemand["limit"]), team > 0 {
                planPercent = team
            }
        }
        // team / enterprise：团队池为准。
        let prefersTeamPool = limitType == "team" || membershipType == "team" || membershipType == "enterprise"
        if prefersTeamPool, planPercent == nil || planPercent == 0 {
            if let team = centsPercent(teamOnDemand["used"], limit: teamOnDemand["limit"]) {
                planPercent = team
            }
        }
        guard let planPercent else { return [:] }

        return [.monthly: UsageWindow(
            usedPercent: planPercent,
            resetAt: cycle.end,
            limit: nil,
            used: nil,
            remaining: nil,
            unit: nil,
            windowSeconds: cycle.seconds
        )]
    }

    /// Auto / API 车道窗（对齐 B secondary/tertiary）：与主窗同 reset 与周期秒数。
    static func laneLabeledWindows(_ object: [String: Any]) -> [LabeledUsageWindow]? {
        guard let cycle = billingCycle(from: object) else { return nil }
        let plan = (object["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] ?? [:]
        let autoPercent = percent(plan["autoPercentUsed"])
        let apiPercent = percent(plan["apiPercentUsed"])
        var labeled: [LabeledUsageWindow] = []
        for (name, value) in [("Auto", autoPercent), ("API", apiPercent)] {
            if let value {
                labeled.append(LabeledUsageWindow(
                    label: name,
                    window: UsageWindow(
                        usedPercent: value,
                        resetAt: cycle.end,
                        limit: nil, used: nil, remaining: nil, unit: nil,
                        windowSeconds: cycle.seconds
                    )
                ))
            }
        }
        return labeled.isEmpty ? nil : labeled
    }

    /// 显示用套餐标签（membershipType）：free/none/unknown/invalid 不可显示 → nil；其余按 `_` 分隔大写。
    static func membershipLabel(_ object: [String: Any]) -> String? {
        let raw = object["membershipType"] as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "free", "none", "unknown", "invalid": return nil
        default:
            return trimmed
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    // MARK: 内部

    private static func billingCycle(from object: [String: Any]) -> (end: Date, seconds: Double?)? {
        guard let endRaw = object["billingCycleEnd"] as? String,
              let end = parseISO(endRaw) else {
            return nil
        }
        let start: Date?
        if let startRaw = object["billingCycleStart"] as? String {
            start = parseISO(startRaw)
        } else {
            start = nil
        }
        let seconds: Double?
        if let start, end > start {
            seconds = end.timeIntervalSince(start)
        } else {
            seconds = nil
        }
        return (end, seconds)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISO(_ value: String) -> Date? {
        isoFractional.date(from: value) ?? isoPlain.date(from: value)
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = UsageWindowParsing.numeric(value) else { return nil }
        return clampPercent(number)
    }

    /// cents used/limit 反推百分比（单位一致，比值即百分比）。
    private static func centsPercent(_ used: Any?, limit: Any?) -> Double? {
        guard let used = UsageWindowParsing.numeric(used),
              let limit = UsageWindowParsing.numeric(limit),
              limit > 0 else {
            return nil
        }
        return clampPercent(used / limit * 100)
    }

    private static func clampPercent(_ value: Double?) -> Double? {
        UsageWindowParsing.clampPercent(value)
    }
}

// MARK: - 取数器

/// Cursor 限额取数器：state.vscdb 拼 cookie → 网页 API `usage-summary`（浏览器伪装头，
/// 手动重定向仅 cursor.com 域）→ 计费周期窗口（参考 08 / cursor-config.js:138）。
///
/// 隔离语义（SPEC 11）：网页 API 随时改版 / Cloudflare 变化 → 解码失败降级为「配置态空窗口」，
/// 单家失败绝不影响其他 provider；401/403 → `reauthRequired`（提示在 Cursor 重新登录）。
final class CursorLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .cursor

    /// usage-summary 端点（集中定义可改）。
    static let usageSummaryEndpoint = CursorWebAPIClient.usageSummaryEndpoint

    private let credentials: CursorCredentialReading
    private let client: CursorWebAPIClient
    private let now: () -> Date

    init(
        credentials: CursorCredentialReading = CursorVSCDBCredentialReader(),
        client: CursorWebAPIClient = CursorWebAPIClient(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.client = client
        self.now = now
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 未配置（state.vscdb 缺失/无 token/无 userId）→ nil，由管理器归一化为 notConfigured。
        guard let bundle: CursorAuthBundle = try? credentials.readBundle() else {
            return nil
        }
        let object: [String: Any]
        do {
            object = try await client.getJSON(
                url: Self.usageSummaryEndpoint,
                headers: CursorBrowserHeaders.headers(cookie: bundle.sessionCookie, accept: "application/json")
            )
        } catch LimitError.decoding {
            // 解析失败降级不崩：返回配置态空窗口（卡片仅显示错误行），单家失败不拖累。
            return providerLimits(windows: [:])
        }
        let planLabel = CursorUsageSummaryDecoder.membershipLabel(object)
        let laneWindows = CursorUsageSummaryDecoder.laneLabeledWindows(object)
        return ProviderUsageLimits(
            provider: .cursor,
            configured: true,
            subscriptionStatus: planLabel != nil ? .active : .unknown,
            planLabel: planLabel,
            windows: CursorUsageSummaryDecoder.decode(object),
            labeledWindows: laneWindows,
            confidence: .official,
            capturedAt: now(),
            stale: false,
            issue: nil
        )
    }

    private func providerLimits(windows: [LimitWindowKind: UsageWindow]) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: .cursor,
            configured: true,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: windows,
            confidence: .official,
            capturedAt: now(),
            stale: false,
            issue: nil
        )
    }
}
