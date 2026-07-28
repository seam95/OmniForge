import XCTest
@testable import OmniForge

final class MonitorPanelConfigurationStateTests: XCTestCase {
    func test_rowsHaveUniqueStableIDsAndIndependentActions() {
        let rows = MonitorPanelConfigurationState.rows(
            configuration: MonitorConfiguration(),
            strings: .zhHans
        )

        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(
            rows.map(\.id),
            MonitorSection.allCases.map { "performance.section.\($0.rawValue)" }
        )
        XCTAssertFalse(rows[0].canMoveUp)
        XCTAssertTrue(rows[0].canMoveDown)
        XCTAssertTrue(rows[0].isVisible)
    }
}
