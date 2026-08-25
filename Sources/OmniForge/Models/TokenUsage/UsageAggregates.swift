import Foundation

// MARK: - 趋势周期

/// 趋势图统计周期（日 / 周 / 月 / 总计）— 对齐 TokenTracker 仪表盘趋势切换器。
///
/// - `day`：当日逐时；`week`：近 7 日逐日；`month`：近 30 日逐日；`total`：全部历史按月。
enum TokenTrendPeriod: String, Codable, CaseIterable, Identifiable {
    case day
    case week
    case month
    case total

    var id: String { rawValue }
}

// MARK: - 日聚合（按本地日 × provider）

/// 一个本地日 × provider 的用量聚合（SQL `GROUP BY day, provider` 行）。
///
/// 隐私红线（SPEC 2.6）：只携带 token 计数 / 会话数 / 日期 / provider，绝无正文。
struct UsageDayProviderAggregate: Equatable {
    /// 本地日零点（由 `yyyy-MM-dd` 本地日串解析）。
    var dayStart: Date
    var provider: TokenUsageProvider
    var totalTokens: Int
    var conversations: Int
}

// MARK: - 模型聚合（按模型名）

/// 一个模型的窗口 token 总量（SQL `GROUP BY model` 行）。
struct UsageModelAggregate: Equatable {
    var model: String
    var totalTokens: Int
}

// MARK: - 日聚合本地日界解析

extension UsageDayProviderAggregate {
    /// 本地 `yyyy-MM-dd` 日串解析器（与 GRDB `date(bucket_start,'unixepoch','localtime')` 对齐）。
    static let localDayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// 由 SQL 返回的本地日串（`yyyy-MM-dd`）构造；解析失败 → nil。
    init?(localDay: String, provider: TokenUsageProvider, totalTokens: Int, conversations: Int) {
        guard let dayStart = Self.localDayParser.date(from: localDay) else { return nil }
        self.init(dayStart: dayStart, provider: provider, totalTokens: totalTokens, conversations: conversations)
    }
}

// MARK: - 日聚合合并（跨 provider）

extension Array where Element == UsageDayProviderAggregate {
    /// 按本地日合并（跨 provider 汇总 token 与会话数）。
    var mergedByDay: [Date: (totalTokens: Int, conversations: Int)] {
        var result: [Date: (totalTokens: Int, conversations: Int)] = [:]
        for entry in self {
            let current = result[entry.dayStart] ?? (0, 0)
            result[entry.dayStart] = (current.totalTokens + entry.totalTokens, current.conversations + entry.conversations)
        }
        return result
    }
}
