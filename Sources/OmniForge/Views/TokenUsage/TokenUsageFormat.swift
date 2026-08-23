import SwiftUI

/// Token 用量展示格式化 — 纯函数，无状态；数字缩写 / 相对时间 / 状态派生。
enum TokenUsageFormat {
    /// 计数缩写：850 → "850"；128_400 → "128.4k"；1_200_000 → "1.2m"。
    /// 保留 1 位小数并去掉尾随 `.0`（"1.0k" → "1k"）。
    static func tokens(_ count: Int) -> String {
        let absCount = abs(Double(count))
        let sign = count < 0 ? "-" : ""
        if absCount >= 1_000_000 {
            return sign + scaled(absCount / 1_000_000) + "m"
        }
        if absCount >= 1_000 {
            return sign + scaled(absCount / 1_000) + "k"
        }
        return "\(count)"
    }

    /// 菜单栏口径计数缩写（SPEC 4.4「如 128k」）：128_400 → "128k"。
    /// 与面板口径 `tokens` 不同：缩到整数 k/m（去掉小数），保证整数口径最长 4 字符。
    static func menubarTokens(_ count: Int) -> String {
        let absCount = abs(Double(count))
        let sign = count < 0 ? "-" : ""
        if absCount >= 1_000_000 {
            return sign + "\(Int(absCount / 1_000_000))m"
        }
        if absCount >= 1_000 {
            return sign + "\(Int(absCount / 1_000))k"
        }
        return "\(count)"
    }

    private static func scaled(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    /// 百分比整数显示（"82%"）。
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// 相对更新时间：<1 分钟 → 刚刚；其余分钟 / 小时。
    static func relativeUpdate(_ date: Date?, now: Date = Date(), strings: Strings) -> String {
        guard let date else { return strings.tokenUpdatedJustNow }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 {
            return strings.tokenUpdatedJustNow
        }
        if minutes < 60 {
            return String(format: strings.tokenUpdatedMinutesFormat, minutes)
        }
        return String(format: strings.tokenUpdatedHoursFormat, minutes / 60)
    }

    /// 人性化时长（展示层口径）：分钟/小时/天，随语言本地化（LimitPace.durationString
    /// 保持紧凑内部口径 "45m"/"3h" 供测试与内部投影）。
    static func duration(_ seconds: TimeInterval, strings: Strings) -> String {
        let s = Int(max(0, seconds))
        let days = s / 86400
        if days > 0 {
            return String(format: strings.tokenDurationDayFormat, days)
        }
        let hours = s / 3600
        if hours > 0 {
            return String(format: strings.tokenDurationHourFormat, hours)
        }
        return String(format: strings.tokenDurationMinuteFormat, s / 60)
    }

    /// 星期简称（周日前置，配合 `tokenWeekdayNames`）。
    static func weekdayName(for date: Date, strings: Strings) -> String {
        let weekday = Calendar.current.component(.weekday, from: date) // 1 = 周日
        let index = max(0, weekday - 1)
        guard index < strings.tokenWeekdayNames.count else { return "" }
        return strings.tokenWeekdayNames[index]
    }

    /// 窗口行说明文案（重置 + 步速结论）；credits 窗口固定额度口径；无 kind（附加带标签窗）仅显示重置时间。
    static func caption(
        for window: UsageWindow,
        kind: LimitWindowKind?,
        pace: LimitPace.Result,
        now: Date,
        strings: Strings
    ) -> String {
        if kind == .credits {
            return strings.tokenCreditCaption
        }
        var parts: [String] = []
        let secondsUntilReset = window.resetAt?.timeIntervalSince(now) ?? 0
        if let resetAt = window.resetAt, resetAt > now {
            parts.append(String(format: strings.tokenResetInApproxFormat, duration(secondsUntilReset, strings: strings)))
        }
        if pace.paceOver {
            parts.append(strings.tokenPaceOver)
        } else if let projectedEnd = pace.projectedEnd {
            parts.append(String(format: strings.tokenPaceProjectedFormat, projectedEnd))
        }
        return parts.joined(separator: " · ")
    }

    /// 错误条说明文案（卡片体为空时使用）。
    static func errorCaption(for issue: LimitError, now: Date, strings: Strings) -> String {
        switch issue {
        case .reauthRequired:
            return strings.tokenReauthHint
        case .rateLimited(let retryAt):
            let seconds = max(0, retryAt.timeIntervalSince(now))
            return String(format: strings.tokenRateLimitedCaptionFormat, duration(seconds, strings: strings))
        case .network:
            return strings.tokenErrorNetwork + " · " + strings.tokenErrorRetryableHint
        case .decoding:
            return strings.tokenErrorTransient + " · " + strings.tokenErrorRetryableHint
        }
    }

    // MARK: 分布行行态（#09 Cursor 云端口径）

    /// 分布行右值：无数据灰显 `--`（纯符号，无需本地化；SPEC 4.2）；有数据接 `tokens` 缩写。
    static func distributionValue(_ entry: UsageDistributionEntry) -> String {
        guard let total = entry.totalTokens else { return "--" }
        return tokens(total)
    }

    /// 该行是否标「云端口径」：仅 Cursor（云端账单，非实时；文案走 `strings.tokenCloudBadge`）。
    static func showsCloudScopeBadge(for entry: UsageDistributionEntry) -> Bool {
        entry.provider == .cursor
    }
}

/// Provider 视觉风格 — 模块色 + 状态色。
extension TokenUsageProvider {
    /// 模块强调色（卡点头部色块 / 进度条正常段）。
    var accentColor: Color {
        switch self {
        case .claude: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: return Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
        case .antigravity: return Color(red: 0x8A / 255, green: 0x5C / 255, blue: 0xF2 / 255)
        case .kimi: return Color(red: 0x5B / 255, green: 0x5B / 255, blue: 0xD6 / 255)
        case .cursor: return Theme.Stats.text3
        }
    }
}

/// 窗口类型展示名。
extension LimitWindowKind {
    func title(_ strings: Strings) -> String {
        switch self {
        case .session: return strings.tokenWindowSession5h
        case .weekly: return strings.tokenWindowWeekly
        case .monthly: return strings.tokenWindowMonthly
        case .credits: return strings.tokenWindowCredits
        }
    }
}

/// 周期名称（今日 / 本周 / 本月）。
extension TokenUsagePeriod {
    func title(in strings: Strings) -> String {
        switch self {
        case .today: return strings.tokenPeriodToday
        case .week: return strings.tokenPeriodWeek
        case .month: return strings.tokenPeriodMonth
        }
    }

    /// 用量卡标题（今日用量 / 本周用量 / 本月用量）。
    func cardTitle(_ strings: Strings) -> String {
        switch self {
        case .today: return strings.tokenTodayCardTitle
        case .week: return strings.tokenWeekCardTitle
        case .month: return strings.tokenMonthCardTitle
        }
    }

    /// 趋势 caption 文案格式（近 7 日趋势 / 本周趋势 / 本月趋势）。
    func trendCaptionFormat(_ strings: Strings) -> String {
        switch self {
        case .today: return strings.tokenTrendCaptionFormat
        case .week: return strings.tokenTrendWeekCaptionFormat
        case .month: return strings.tokenTrendMonthCaptionFormat
        }
    }
}

/// 卡片整体状态 — 驱动 StatusTintBadge 文案与颜色。
enum TokenUsageCardStatus {
    case normal
    case approaching
    case exceeded
    case reauth
    case rateLimited
    case stale
    case transient

    /// 从限额快照派生状态（错误优先；stale 回退标「数据可能过期」，其次会话窗用量阈值）。
    static func derive(from limits: ProviderUsageLimits) -> TokenUsageCardStatus {
        if let issue = limits.issue {
            switch issue {
            case .reauthRequired: return .reauth
            case .rateLimited: return .rateLimited
            case .network, .decoding:
                // 显示 last-good 快照 + 行内错误提示 → 徽章强调数据可能过期
                return limits.stale && !limits.windows.isEmpty ? .stale : .transient
            }
        }
        guard let session = limits.windows[.session],
              limits.windows[.credits] == nil else {
            // 无会话窗（或只有额度窗）→ 无用量阈值可言
            return .normal
        }
        let percent = session.usedPercent
        // 阈值对齐 TokenTracker：≥70 approaching / ≥90 exceeded。
        if percent >= 90 { return .exceeded }
        if percent >= 70 { return .approaching }
        return .normal
    }

    /// 徽章文案（需注入本地化）。
    func label(_ strings: Strings) -> String {
        switch self {
        case .normal: return strings.tokenStatusNormal
        case .approaching: return strings.tokenStatusApproaching
        case .exceeded: return strings.tokenStatusExceeded
        case .reauth: return strings.tokenStatusReauth
        case .rateLimited: return strings.tokenStatusRateLimited
        case .stale: return strings.tokenStatusStale
        case .transient: return strings.tokenErrorTransient
        }
    }

    var tint: Color {
        switch self {
        case .normal: return Theme.Stats.statusNormal
        case .approaching: return Theme.Stats.ram
        case .exceeded, .reauth: return Theme.Stats.up
        case .rateLimited, .stale: return Theme.Stats.ram
        case .transient: return Theme.Stats.text3
        }
    }

    /// 警告图标（说明行前置），仅异常态显示。
    var showsWarningIcon: Bool {
        switch self {
        case .normal: return false
        case .approaching, .exceeded, .reauth, .rateLimited, .stale, .transient: return true
        }
    }
}
