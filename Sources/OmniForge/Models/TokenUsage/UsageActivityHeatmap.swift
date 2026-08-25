import Foundation

// MARK: - 活跃度热力图快照

/// 热力图单元格：一个本地日（0 = 无数据；1...4 = 有数据的强度档位）。
struct UsageActivityHeatmapCell: Equatable {
    var dayStart: Date
    var totalTokens: Int
    var level: Int
}

/// 活跃度热力图快照：周列 × 7 行网格 + 窗口内活跃日计数。
struct UsageActivityHeatmap: Equatable {
    /// 每列一周（7 格，含 nil 占位）；列序旧 → 新，末列为本周（可能不完整）。
    var weeks: [[UsageActivityHeatmapCell?]]
    var activeDays: Int
}

// MARK: - 热力图构建器

/// 从日聚合（已按 provider 过滤）构建年度热力图 — 纯函数。
///
/// 语义（对齐 TokenTracker GitHub 风格热力图）：
/// - 窗口 = 含本周在内的 `weekCount` 周；起始列从 `calendar.firstWeekday` 对齐的周一起排；
/// - 网格覆盖 [gridStart, 今日] 的真实日，未来日与窗口外占位为 nil；
/// - 强度档位：0 = 无数据；有数据按 `tokens / 窗口最大日` 比例取 `ceil(fraction * 4)` 夹到 1...4；
/// - `activeDays` = 窗口内有数据的本地日数。
enum UsageHeatmapBuilder {
    static let defaultWeekCount = 53

    static func make(
        daily: [UsageDayProviderAggregate],
        now: Date,
        calendar: Calendar,
        weekCount: Int = defaultWeekCount
    ) -> UsageActivityHeatmap? {
        let byDay = daily.mergedByDay
        guard !byDay.isEmpty else { return nil }

        let todayStart = calendar.startOfDay(for: now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let lastWeekStart = thisWeek.start
        guard let gridStart = calendar.date(byAdding: .day, value: -(weekCount - 1) * 7, to: lastWeekStart) else {
            return nil
        }

        let maxTokens = byDay.values.map(\.totalTokens).max() ?? 0

        var weeks: [[UsageActivityHeatmapCell?]] = []
        var activeDays = 0
        for column in 0..<weekCount {
            guard let columnStart = calendar.date(byAdding: .day, value: column * 7, to: gridStart) else { break }
            var week: [UsageActivityHeatmapCell?] = []
            for row in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: row, to: columnStart) else { continue }
                // 窗口外（早于网格起点）与未来日 → nil 占位。
                guard day >= gridStart, day <= todayStart else {
                    week.append(nil)
                    continue
                }
                let total = byDay[day]?.totalTokens ?? 0
                if total > 0 { activeDays += 1 }
                week.append(
                    UsageActivityHeatmapCell(
                        dayStart: day,
                        totalTokens: total,
                        level: level(for: total, maxTokens: maxTokens)
                    )
                )
            }
            weeks.append(week)
        }
        return UsageActivityHeatmap(weeks: weeks, activeDays: activeDays)
    }

    /// 强度档位：0 = 无数据；有数据按占比 1...4（任何正数至少 1 档）。
    static func level(for tokens: Int, maxTokens: Int) -> Int {
        guard tokens > 0, maxTokens > 0 else { return 0 }
        let fraction = Double(tokens) / Double(maxTokens)
        return min(4, max(1, Int(ceil(fraction * 4))))
    }
}
