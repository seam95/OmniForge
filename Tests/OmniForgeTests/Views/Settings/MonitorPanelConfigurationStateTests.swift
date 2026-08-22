import XCTest
@testable import OmniForge

final class MonitorPanelConfigurationStateTests: XCTestCase {
    func test_rowsHaveUniqueStableIDsAndFollowAllCasesOrder() {
        let rows = MonitorPanelConfigurationState.rows(
            configuration: MonitorConfiguration(),
            strings: .zhHans
        )

        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(
            rows.map(\.id),
            MonitorSection.allCases.map { "performance.section.\($0.rawValue)" }
        )
        XCTAssertTrue(rows.allSatisfy { $0.isVisible })
    }

    func test_rowsReflectHiddenSections() {
        var config = MonitorConfiguration()
        config.visibleSections = [.system, .network]
        let rows = MonitorPanelConfigurationState.rows(
            configuration: config,
            strings: .zhHans
        )
        XCTAssertTrue(rows.first { $0.section == .system }?.isVisible == true)
        XCTAssertTrue(rows.first { $0.section == .network }?.isVisible == true)
        XCTAssertTrue(rows.first { $0.section == .disk }?.isVisible == false)
        XCTAssertTrue(rows.first { $0.section == .power }?.isVisible == false)
    }
}
