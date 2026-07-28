import XCTest
@testable import OmniForge

final class ClipboardHistoryGroupingTests: XCTestCase {
    func test_groupsEntriesInOneExclusiveTimeSection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))
        )
        let dates = [
            DateComponents(year: 2026, month: 7, day: 15, hour: 10),
            DateComponents(year: 2026, month: 7, day: 14, hour: 10),
            DateComponents(year: 2026, month: 7, day: 13, hour: 10),
            DateComponents(year: 2026, month: 7, day: 8, hour: 10),
            DateComponents(year: 2026, month: 7, day: 1, hour: 10),
            DateComponents(year: 2026, month: 1, day: 15, hour: 10)
        ]
        let entries = try dates.enumerated().map { index, components in
            ClipboardEntry(
                id: UUID(),
                createdAt: try XCTUnwrap(calendar.date(from: components)),
                type: .text,
                preview: "\(index)",
                sourceAppBundleID: nil,
                sourceAppName: nil,
                content: .text("\(index)")
            )
        }

        let groups = ClipboardHistoryGrouper.groups(
            entries: entries,
            calendar: calendar,
            now: now
        )
        let groupedIDs = groups.flatMap(\.entries).map(\.id)

        XCTAssertEqual(groupedIDs, entries.map(\.id))
        XCTAssertEqual(Set(groupedIDs).count, entries.count)
        XCTAssertEqual(
            groups.map(\.section.rawValue),
            [
                "today",
                "yesterday",
                "thisWeek",
                "lastWeek",
                "thisMonth",
                "thisYear"
            ]
        )
    }
}
