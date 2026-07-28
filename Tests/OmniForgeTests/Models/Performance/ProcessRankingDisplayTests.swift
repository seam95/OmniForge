import XCTest
@testable import OmniForge

final class ProcessRankingDisplayTests: XCTestCase {
    func test_displayLimitIsThirtyAndSharedContract() {
        XCTAssertEqual(ProcessRankingDisplay.limit, 30)
        // 采样与 UI 都必须大于原 15，避免回归。
        XCTAssertGreaterThan(ProcessRankingDisplay.limit, 15)
    }
}
