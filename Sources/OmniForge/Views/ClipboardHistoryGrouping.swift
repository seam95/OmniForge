import Foundation

/// 剪贴板历史分组的时间段枚举
enum ClipboardSection: String, CaseIterable, Hashable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case thisYear

    static let sortOrder: [ClipboardSection] = [
        .today, .yesterday, .thisWeek, .lastWeek, .thisMonth, .thisYear
    ]

    func title(in strings: Strings) -> String {
        switch self {
        case .today: return strings.clipboardSectionToday
        case .yesterday: return strings.clipboardSectionYesterday
        case .thisWeek: return strings.clipboardSectionThisWeek
        case .lastWeek: return strings.clipboardSectionLastWeek
        case .thisMonth: return strings.clipboardSectionThisMonth
        case .thisYear: return strings.clipboardSectionThisYear
        }
    }
}

struct ClipboardHistoryGroup: Identifiable {
    let section: ClipboardSection
    var entries: [ClipboardEntry]
    var id: String { section.rawValue }
}

enum ClipboardHistoryGrouper {
    static func groups(
        entries: [ClipboardEntry],
        calendar inputCalendar: Calendar = .current,
        now: Date = Date()
    ) -> [ClipboardHistoryGroup] {
        var calendar = inputCalendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        var buckets: [ClipboardSection: [ClipboardEntry]] = [:]
        for entry in entries {
            guard let section = section(for: entry.createdAt, calendar: calendar, now: now) else {
                continue
            }
            buckets[section, default: []].append(entry)
        }

        return ClipboardSection.sortOrder.compactMap { section in
            guard let entries = buckets[section], !entries.isEmpty else { return nil }
            return ClipboardHistoryGroup(section: section, entries: entries)
        }
    }

    private static func section(
        for date: Date,
        calendar: Calendar,
        now: Date
    ) -> ClipboardSection? {
        if calendar.isDate(date, inSameDayAs: now) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) {
            return .lastWeek
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            return .thisMonth
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return .thisYear
        }
        return nil
    }
}
