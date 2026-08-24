import Foundation

/// 已接入的 AI CLI provider。
enum TokenUsageProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case antigravity
    case kimi
    case cursor
    case deepSeek = "deepseek"
    // 多供应商接入（2026-08-24）：9 家新 provider。
    case opencode
    case codebuddy
    case workbuddy
    case grok
    case zcode
    case traeCN = "trae-cn"
    case qoder
    case dsh
    case arkCodingPlan = "ark-coding-plan"

    var id: String { rawValue }

    /// 展示名（品牌名，不随语言变化）。
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        case .cursor: return "Cursor"
        case .deepSeek: return "DeepSeek"
        case .opencode: return "opencode"
        case .codebuddy: return "CodeBuddy"
        case .workbuddy: return "WorkBuddy"
        case .grok: return "Grok"
        case .zcode: return "ZCode"
        case .traeCN: return "Trae CN"
        case .qoder: return "Qoder"
        case .dsh: return "DSH"
        case .arkCodingPlan: return "方舟 Coding Plan"
        }
    }
}

/// 限额窗口周期类型。
enum LimitWindowKind: String, Codable, CaseIterable {
    case session
    case weekly
    case monthly
    case credits
}

/// 单个限额窗口（参考 03）。
struct UsageWindow: Codable, Equatable {
    /// 已用百分比，已 clamp 到 0…100。
    var usedPercent: Double
    var resetAt: Date?
    /// 额度型窗口：上限 / 已用 / 剩余。
    var limit: Double?
    var used: Double?
    var remaining: Double?
    var unit: String?
    /// 窗口时长（秒）。可信才允许画 LimitPace 刻度；月度/计费周期通常无值。
    var windowSeconds: Double?
}

/// 数据点置信度（参考 03）：官方 API 直读 / 本地库观测 / 本地估算。
enum LimitConfidence: String, Codable, Equatable {
    case official
    case observed
    case inferred
}

enum SubscriptionStatus: String, Codable, Equatable {
    case active
    case inactive
    case unknown
}

/// 限额取数错误 — 与「未配置」分开建模；Codable 以便持久化到磁盘缓存。
enum LimitError: Error, Equatable, Codable {
    case reauthRequired
    case rateLimited(retryAt: Date)
    case network(String)
    case decoding(String)
}

/// 带标签的附加窗口 — provider 特有的细分窗口，不占用语义槽位
/// （Claude Opus 周窗 / weekly_scoped、Cursor Auto/API 车道、Codex Spark、Antigravity Gemini 双窗）。
struct LabeledUsageWindow: Codable, Equatable {
    var label: String
    var window: UsageWindow
}

/// Codex 重置权益明细（参考 B ResetCredits）：仅保留可用且未过期的 credit 行，
/// 按过期时间升序；count 缺失但有明细时以明细数为准。
struct UsageResetBank: Codable, Equatable {
    var availableCount: Int?
    var totalEarnedCount: Int?
    var credits: [UsageResetCreditEntry]

    /// 可展示行数：优先官方 count，否则明细数。
    var displayCount: Int? { availableCount ?? (credits.isEmpty ? nil : credits.count) }
}

/// 单条重置权益。
struct UsageResetCreditEntry: Codable, Equatable {
    var grantedAt: Date?
    var expiresAt: Date
}

/// 单个 provider 的限额快照（聚合层统一补齐置信度/新鲜度元数据）。
struct ProviderUsageLimits: Codable, Equatable {
    var provider: TokenUsageProvider
    var configured: Bool
    var subscriptionStatus: SubscriptionStatus
    var planLabel: String?
    var windows: [LimitWindowKind: UsageWindow]
    /// 附加带标签窗口（可选：旧磁盘缓存 decodeIfPresent 兼容）。
    var labeledWindows: [LabeledUsageWindow]?
    /// Codex 重置权益明细（其余 provider 恒 nil）。
    var resetBank: UsageResetBank?
    var confidence: LimitConfidence
    var capturedAt: Date
    var stale: Bool
    var issue: LimitError?

    init(
        provider: TokenUsageProvider,
        configured: Bool,
        subscriptionStatus: SubscriptionStatus,
        planLabel: String?,
        windows: [LimitWindowKind: UsageWindow],
        labeledWindows: [LabeledUsageWindow]? = nil,
        resetBank: UsageResetBank? = nil,
        confidence: LimitConfidence,
        capturedAt: Date,
        stale: Bool,
        issue: LimitError?
    ) {
        self.provider = provider
        self.configured = configured
        self.subscriptionStatus = subscriptionStatus
        self.planLabel = planLabel
        self.windows = windows
        self.labeledWindows = labeledWindows
        self.resetBank = resetBank
        self.confidence = confidence
        self.capturedAt = capturedAt
        self.stale = stale
        self.issue = issue
    }

    static func notConfigured(_ provider: TokenUsageProvider, at date: Date = Date()) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: false,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: [:],
            confidence: .inferred,
            capturedAt: date,
            stale: false,
            issue: nil
        )
    }
}

// MARK: - 解析工具

/// 窗口/百分比/reset_at 的解析清洗 — 纯函数，独立可测（参考 03）。
enum UsageWindowParsing {
    /// 已用百分比 clamp 到 0…100；nil / 非有限值 → nil。
    static func clampPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    /// reset_at 多格式统一：unix 秒 / 毫秒 / ISO8601 字符串 / Date。
    /// 数值 `< 1e12` 视为秒，否则已是毫秒。
    static func parseResetDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = numeric(value), number > 0 {
            return Date(timeIntervalSince1970: number < 1e12 ? number : number / 1000)
        }
        if let string = value as? String {
            if let double = Double(string), double > 0 {
                return Date(timeIntervalSince1970: double < 1e12 ? double : double / 1000)
            }
            // ISO8601 带/不带毫秒两个变体（默认 withInternetDateTime 不吞小数秒）
            if let date = isoFractional.date(from: string) {
                return date
            }
            return isoPlain.date(from: string)
        }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /// 数字或数字字符串 → Double；其余 nil。
    static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    /// 秒 → 窗口类型：18000 = 会话（5h）、604800 = 周（7d）。
    static func windowKind(forSeconds seconds: Double) -> LimitWindowKind? {
        switch seconds {
        case 18000: return .session
        case 604800: return .weekly
        default: return nil
        }
    }

    /// 窗口可用性：有 used_percent / utilization 或 limit/used 可反推百分比才保留（否则丢弃，绝不显示 0%）。
    static func windowIfUsable(_ raw: [String: Any]) -> UsageWindow? {
        let hasPercent = numeric(raw["used_percent"]) != nil
            || numeric(raw["used_pct"]) != nil
            || numeric(raw["utilization"]) != nil
        let hasRatio = (numeric(raw["limit"]) ?? 0) > 0 && numeric(raw["used"]) != nil
        guard hasPercent || hasRatio else { return nil }
        return makeWindow(from: raw)
    }

    /// 把原始窗口字典（含 used_percent/reset_at/limit_window_seconds 等字段）清洗为 `UsageWindow`。
    static func makeWindow(from raw: [String: Any]) -> UsageWindow {
        let seconds = numeric(raw["limit_window_seconds"]) ?? numeric(raw["window_seconds"])
        let limit = numeric(raw["limit"]) ?? numeric(raw["total_limit_amount"])
        let used = numeric(raw["used"])
        let remaining = numeric(raw["remaining"])
        var usedPercent = clampPercent(
            numeric(raw["used_percent"]) ?? numeric(raw["used_pct"]) ?? numeric(raw["utilization"])
        )
        // 额度型窗口：limit/used 齐全时用 used/limit 反推百分比兜底
        if usedPercent == nil, let limit, limit > 0, let used {
            usedPercent = clampPercent(used / limit * 100)
        }
        return UsageWindow(
            usedPercent: usedPercent ?? 0,
            resetAt: parseResetDate(raw["reset_at"] ?? raw["resets_at"] ?? raw["next_reset_at"]),
            limit: limit,
            used: used,
            remaining: remaining,
            unit: raw["unit"] as? String,
            windowSeconds: seconds
        )
    }
}
