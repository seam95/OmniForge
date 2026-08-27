import Foundation

/// Claude 官方限额响应解码 — 防御式 JSON 解析（端点可能带多余字段，解析失败降级不崩）。
///
/// 字段（参考 06/08）：`five_hour` / `seven_day` / `seven_day_opus` / `weekly_scoped` / `extra_usage`。
/// 窗口按秒数分类为主（18000=会话 / 604800=周），槽位名兜底（参考 03）；
/// `seven_day_opus` 与新式 `limits[]` 数组中的 `weekly_scoped` 条目进 labeledWindows
/// （对齐 B extractClaudeScopedWeekly：scoped 中与 seven_day_opus 重复的 opus 条目去重丢弃）。
enum ClaudeUsageResponseDecoder {
    static func decode(_ object: [String: Any]) -> [LimitWindowKind: UsageWindow] {
        var windows: [LimitWindowKind: UsageWindow] = [:]

        // 候选窗口：键名直取 + weekly_scoped 展开
        var candidates: [(key: String, raw: [String: Any])] = []
        for key in ["five_hour", "seven_day", "seven_day_opus", "weekly_scoped"] {
            if let raw = object[key] as? [String: Any] {
                candidates.append((key, raw))
            }
        }

        // 按秒数分类：session / weekly 首位命中；无秒数时按键名兜底
        var session: UsageWindow?
        var weekly: UsageWindow?
        for (key, raw) in candidates {
            let window = UsageWindowParsing.makeWindow(from: raw)
            if let seconds = window.windowSeconds {
                switch UsageWindowParsing.windowKind(forSeconds: seconds) {
                case .session:
                    if session == nil { session = window }
                case .weekly:
                    if weekly == nil { weekly = window }
                default:
                    break
                }
                continue
            }
            // 无秒数 → 键名兜底
            if key == "five_hour", session == nil { session = window }
            if key == "seven_day", weekly == nil { weekly = window }
        }
        if let session { windows[.session] = session }
        if let weekly { windows[.weekly] = weekly }

        if let extra = object["extra_usage"] as? [String: Any] {
            windows[.credits] = decodeCredits(extra)
        }
        return windows
    }

    /// 模型级周窗：顶层 `seven_day_opus`（label "Opus"）+ 新式 `limits[]`
    /// 数组中 `kind == "weekly_scoped"` 条目（label 取 scope.model.display_name 回退 id）。
    /// scoped 条目与 seven_day_opus 重复（label "opus"）时去重丢弃——同一窗口不渲染两次。
    static func decodeLabeledScopedWeekly(_ object: [String: Any]) -> [LabeledUsageWindow] {
        var result: [LabeledUsageWindow] = []

        if let raw = object["seven_day_opus"] as? [String: Any],
           var window = UsageWindowParsing.windowIfUsable(raw) {
            window.windowSeconds = 7 * 24 * 3600
            result.append(LabeledUsageWindow(label: "Opus", window: window))
        }
        let hasSevenDayOpus = object["seven_day_opus"] != nil

        guard let entries = object["limits"] as? [[String: Any]] else {
            return result
        }
        for entry in entries where entry["kind"] as? String == "weekly_scoped" {
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            let candidates = [
                (model?["display_name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                model?["id"] as? String,
                (entry["scope"] as? [String: Any])?["model_id"] as? String,
            ]
            let label = candidates.first { $0 != nil && !$0!.isEmpty } ?? nil
            guard let label else { continue }
            // 已有顶层 seven_day_opus 时，重复的 Opus scoped 条目跳过。
            if hasSevenDayOpus, label.lowercased() == "opus" { continue }
            var mapped: [String: Any] = [:]
            if let percent = UsageWindowParsing.numeric(entry["percent"]) ?? UsageWindowParsing.numeric(entry["utilization"]) {
                mapped["used_percent"] = percent
            }
            if let resetsAt = entry["resets_at"] {
                mapped["reset_at"] = resetsAt
            }
            guard var window = UsageWindowParsing.windowIfUsable(mapped) else { continue }
            window.windowSeconds = 7 * 24 * 3600
            result.append(LabeledUsageWindow(label: label, window: window))
        }
        return result
    }

    /// 额度型窗口：`total_limit.amount`（上限）、`payg_used.amount`（已用）、`resets_at`。
    /// 反推百分比由 `UsageWindowParsing.makeWindow` 兜底。
    private static func decodeCredits(_ raw: [String: Any]) -> UsageWindow {
        var mapped = raw
        if let totalLimit = raw["total_limit"] as? [String: Any] {
            mapped["limit"] = totalLimit["amount"]
            mapped["unit"] = totalLimit["currency"]
        }
        if let paygUsed = raw["payg_used"] as? [String: Any],
           let amount = paygUsed["amount"] {
            mapped["used"] = amount
        }
        if mapped["reset_at"] == nil {
            mapped["reset_at"] = raw["resets_at"]
        }
        // 反推 remaining
        if mapped["remaining"] == nil,
           let limit = UsageWindowParsing.numeric(mapped["limit"]),
           let used = UsageWindowParsing.numeric(mapped["used"]) {
            mapped["remaining"] = max(0, limit - used)
        }
        return UsageWindowParsing.makeWindow(from: mapped)
    }

    /// 订阅状态（响应中的 plan_type / subscription_status，缺失 → unknown）。
    static func decodeSubscriptionStatus(_ object: [String: Any]) -> SubscriptionStatus {
        if let planType = object["plan_type"] as? String {
            switch planType.lowercased() {
            case "free", "none", "unknown", "invalid": return .inactive
            default: return .active
            }
        }
        if let status = object["subscription_status"] as? String {
            switch status.lowercased() {
            case "active": return .active
            case "inactive", "expired": return .inactive
            default: return .unknown
            }
        }
        return .unknown
    }
}

/// Claude 限额取数器：Keychain 凭证 → `api.anthropic.com/api/oauth/usage`（参考 06）。
final class ClaudeLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider = .claude
    private let credentials: ClaudeCredentialReading
    private let client: ProviderAPIClient

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    init(
        credentials: ClaudeCredentialReading = ClaudeKeychainCredentialReader(),
        client: ProviderAPIClient = ProviderAPIClient()
    ) {
        self.credentials = credentials
        self.client = client
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        // 探测存在性（不触碰秘密）；从未登录 → 未配置（nil，由管理器归一化为 notConfigured）。
        guard credentials.probe() else {
            return nil
        }
        let accessToken: String
        do {
            guard let token = try credentials.readAccessToken() else {
                return nil // 探测后条目被移除（用户登出）的竞态
            }
            accessToken = token
        } catch CredentialReadError.invalidPayload {
            // 条目在但 token 空/坏：Claude Code 登录过期时会原地清空 token 而
            // 不删条目——这是「需要重新登录」而非「未配置」。
            throw LimitError.reauthRequired
        } catch CredentialReadError.keychainUnavailable {
            return nil // 读取被拒（授权弹窗未通过）→ 降级未配置
        }

        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
        ]
        let object = try await client.getJSON(url: Self.endpoint, headers: headers)
        let labeled = ClaudeUsageResponseDecoder.decodeLabeledScopedWeekly(object)
        return ProviderUsageLimits(
            provider: .claude,
            configured: true,
            subscriptionStatus: ClaudeUsageResponseDecoder.decodeSubscriptionStatus(object),
            planLabel: credentials.planLabel(),
            windows: ClaudeUsageResponseDecoder.decode(object),
            labeledWindows: labeled.isEmpty ? nil : labeled,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: nil
        )
    }
}
