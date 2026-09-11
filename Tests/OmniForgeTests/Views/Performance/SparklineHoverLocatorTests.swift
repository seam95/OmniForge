import XCTest
@testable import OmniForge

final class SparklineHoverLocatorTests: XCTestCase {
    // MARK: - 悬停点定位

    func test_index_mapsMidpointToNearestSample() {
        // 5 个点均布在 200pt：x=50 恰在 index 1
        XCTAssertEqual(SparklineHoverLocator.index(atX: 50, width: 200, count: 5), 1)
    }

    func test_index_roundsToNearestSample() {
        // 3 个点均布在 100pt：x=40 更接近 index 1
        XCTAssertEqual(SparklineHoverLocator.index(atX: 40, width: 100, count: 3), 1)
    }

    func test_index_clampsToValidRange() {
        XCTAssertEqual(SparklineHoverLocator.index(atX: -10, width: 100, count: 3), 0)
        XCTAssertEqual(SparklineHoverLocator.index(atX: 500, width: 100, count: 3), 2)
    }

    func test_index_returnsNilWhenNotEnoughSamples() {
        XCTAssertNil(SparklineHoverLocator.index(atX: 50, width: 100, count: 0))
        XCTAssertNil(SparklineHoverLocator.index(atX: 50, width: 100, count: 1))
    }

    func test_index_returnsNilForZeroWidth() {
        XCTAssertNil(SparklineHoverLocator.index(atX: 50, width: 0, count: 3))
    }

    // MARK: - 气泡对齐三档（锚点下方悬挂）

    func test_bubbleAlignment_leadsOnLeftThird() {
        XCTAssertEqual(SparklineHoverLocator.bubbleAlignment(atX: 10, width: 300), .topLeading)
    }

    func test_bubbleAlignment_centersInMiddle() {
        XCTAssertEqual(SparklineHoverLocator.bubbleAlignment(atX: 150, width: 300), .top)
    }

    func test_bubbleAlignment_trailsOnRightThird() {
        XCTAssertEqual(SparklineHoverLocator.bubbleAlignment(atX: 290, width: 300), .topTrailing)
    }
}
