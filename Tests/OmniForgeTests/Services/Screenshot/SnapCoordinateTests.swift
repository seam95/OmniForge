import OmniForge
@testable import OmniForge
import XCTest

final class SnapCoordinateTests: XCTestCase {
    private let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 800)
    private let secondaryFrame = NSRect(x: 1440, y: 0, width: 1440, height: 800)

    func test_viewPointToCGPoint_primaryScreen() {
        let cg = SnapCoordinate.cgPoint(
            viewPoint: NSPoint(x: 10, y: 20),
            screenFrame: screenFrame,
            primaryDisplayHeight: 800
        )
        XCTAssertEqual(cg.x, 10, accuracy: 0.001)
        XCTAssertEqual(cg.y, 780, accuracy: 0.001)
    }

    func test_viewRectFromCGRect_primaryScreen() {
        let viewRect = SnapCoordinate.viewRect(
            cgRect: CGRect(x: 10, y: 100, width: 200, height: 50),
            screenFrame: screenFrame,
            primaryDisplayHeight: 800
        )
        XCTAssertEqual(viewRect.minX, 10, accuracy: 0.001)
        XCTAssertEqual(viewRect.minY, 650, accuracy: 0.001)
        XCTAssertEqual(viewRect.width, 200, accuracy: 0.001)
        XCTAssertEqual(viewRect.height, 50, accuracy: 0.001)
    }

    func test_viewPointToCGPoint_secondaryDisplayOffset() {
        let cg = SnapCoordinate.cgPoint(
            viewPoint: NSPoint(x: 5, y: 15),
            screenFrame: secondaryFrame,
            primaryDisplayHeight: 800
        )
        XCTAssertEqual(cg.x, 1445, accuracy: 0.001)
        XCTAssertEqual(cg.y, 785, accuracy: 0.001)
    }

    func test_roundTrip_rectToCGBackToView() {
        let original = CGRect(x: 30, y: 40, width: 100, height: 60)
        let frame900 = NSRect(x: 1000, y: 0, width: 1440, height: 900)
        let viewRect = SnapCoordinate.viewRect(
            cgRect: original,
            screenFrame: frame900,
            primaryDisplayHeight: 900
        )
        // 主屏高度 900：AppKit.y = 900 - 40 - 60 = 800；视图 y = 800 - screen.minY
        XCTAssertEqual(viewRect.minY, 800 - 0, accuracy: 0.001)
    }

    /// 副屏在主屏上方时，必须以主屏高度翻转，不能用副屏 maxY。
    func test_viewPointToCGPoint_secondaryAbovePrimary() {
        // 主屏 (0,0,1440,900)；副屏叠在上方 (0,900,1440,800)
        let secondaryAbove = NSRect(x: 0, y: 900, width: 1440, height: 800)
        let primaryHeight: CGFloat = 900
        let cg = SnapCoordinate.cgPoint(
            viewPoint: NSPoint(x: 5, y: 15),
            screenFrame: secondaryAbove,
            primaryDisplayHeight: primaryHeight
        )
        // AppKit 全局 = (5, 915)；CG.y = 900 - 915 = -15
        XCTAssertEqual(cg.x, 5, accuracy: 0.001)
        XCTAssertEqual(cg.y, -15, accuracy: 0.001)
    }

    /// 副屏高度与主屏不同、底对齐时，旧公式 screen.maxY - y 仍碰巧正确；
    /// 用 primaryDisplayHeight 显式保证语义。
    func test_viewPointToCGPoint_unequalHeightSecondaryAlignedBottom() {
        let secondaryTall = NSRect(x: 1440, y: 0, width: 1280, height: 1024)
        let primaryHeight: CGFloat = 800
        let cg = SnapCoordinate.cgPoint(
            viewPoint: NSPoint(x: 10, y: 20),
            screenFrame: secondaryTall,
            primaryDisplayHeight: primaryHeight
        )
        // AppKit = (1450, 20)；CG.y = 800 - 20 = 780
        XCTAssertEqual(cg.x, 1450, accuracy: 0.001)
        XCTAssertEqual(cg.y, 780, accuracy: 0.001)
    }

    func test_viewRect_secondaryAbovePrimary_usesPrimaryHeight() {
        let secondaryAbove = NSRect(x: 0, y: 900, width: 1440, height: 800)
        let primaryHeight: CGFloat = 900
        // CG 全局矩形对应 AppKit (100, 1000, 200, 50) → 在副屏视图内 (100, 100)
        let cgRect = CGRect(x: 100, y: primaryHeight - 1050, width: 200, height: 50) // y = -150
        let viewRect = SnapCoordinate.viewRect(
            cgRect: cgRect,
            screenFrame: secondaryAbove,
            primaryDisplayHeight: primaryHeight
        )
        XCTAssertEqual(viewRect.minX, 100, accuracy: 0.001)
        XCTAssertEqual(viewRect.minY, 100, accuracy: 0.001)
        XCTAssertEqual(viewRect.width, 200, accuracy: 0.001)
        XCTAssertEqual(viewRect.height, 50, accuracy: 0.001)
    }
}
