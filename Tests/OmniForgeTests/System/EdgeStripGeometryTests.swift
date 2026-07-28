import CoreGraphics
import XCTest
@testable import OmniForge

/// EdgeStripGeometry 纯函数测试。
///
/// 坐标约定：CG 全局坐标（左上原点，Y 向下）。
/// 主屏示例：frame=(0,0,1440,900)；visibleFrame 扣除顶部 24pt 菜单栏 + 底部 80pt Dock → (0,80,1440,796)。
final class EdgeStripGeometryTests: XCTestCase {
    // 主屏：顶部 24pt 菜单栏，底部 80pt Dock，无侧边。
    private let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visibleFrame = CGRect(x: 0, y: 80, width: 1440, height: 796)
    // minY(visibleFrame)=80, maxY(visibleFrame)=876

    // MARK: - strip(at:)

    func test_strip_顶部菜单栏条带命中() {
        // CG y∈[876,900] 为菜单栏区
        XCTAssertEqual(EdgeStripGeometry.strip(at: CGPoint(x: 720, y: 888), screenFrame: screenFrame, visibleFrame: visibleFrame), .menuBar)
        XCTAssertEqual(EdgeStripGeometry.strip(at: CGPoint(x: 0, y: 876), screenFrame: screenFrame, visibleFrame: visibleFrame), .menuBar)
    }

    func test_strip_底部Dock条带命中() {
        // CG y∈[0,80] 为底部 Dock 区
        XCTAssertEqual(EdgeStripGeometry.strip(at: CGPoint(x: 720, y: 40), screenFrame: screenFrame, visibleFrame: visibleFrame), .dockBottom)
        XCTAssertEqual(EdgeStripGeometry.strip(at: CGPoint(x: 720, y: 80), screenFrame: screenFrame, visibleFrame: visibleFrame), .dockBottom)
    }

    func test_strip_屏中央返回nil() {
        XCTAssertNil(EdgeStripGeometry.strip(at: CGPoint(x: 720, y: 450), screenFrame: screenFrame, visibleFrame: visibleFrame))
    }

    func test_strip_屏外返回nil() {
        XCTAssertNil(EdgeStripGeometry.strip(at: CGPoint(x: -50, y: 450), screenFrame: screenFrame, visibleFrame: visibleFrame))
        XCTAssertNil(EdgeStripGeometry.strip(at: CGPoint(x: 2000, y: 450), screenFrame: screenFrame, visibleFrame: visibleFrame))
    }

    func test_strip_左右Dock条带命中() {
        // 副屏带侧边 Dock：frame=(2000,0,1280,800), visibleFrame 左侧内缩 80
        let frame = CGRect(x: 2000, y: 0, width: 1280, height: 800)
        let visible = CGRect(x: 2080, y: 0, width: 1200, height: 800)
        XCTAssertEqual(EdgeStripGeometry.strip(at: CGPoint(x: 2010, y: 400), screenFrame: frame, visibleFrame: visible), .dockLeft)

        // 右侧 Dock
        let visibleR = CGRect(x: 2000, y: 0, width: 1200, height: 800)
        XCTAssertEqual(EdgeStripGeometry.strip(at: CGPoint(x: 3270, y: 400), screenFrame: frame, visibleFrame: visibleR), .dockRight)
    }

    func test_strip_无菜单栏的副屏顶部不吸附() {
        // 外接屏通常无菜单栏：topGap≈0 → 顶部条带不命中
        let frame = CGRect(x: 2000, y: 0, width: 1280, height: 800)
        let visible = CGRect(x: 2000, y: 0, width: 1280, height: 800) // 无内缩
        XCTAssertNil(EdgeStripGeometry.strip(at: CGPoint(x: 2600, y: 799), screenFrame: frame, visibleFrame: visible))
    }

    // MARK: - cgRect(of:)

    func test_cgRect_菜单栏矩形() {
        let r = EdgeStripGeometry.cgRect(of: .menuBar, screenFrame: screenFrame, visibleFrame: visibleFrame)
        XCTAssertEqual(r, CGRect(x: 0, y: 876, width: 1440, height: 24))
    }

    func test_cgRect_底部Dock矩形() {
        let r = EdgeStripGeometry.cgRect(of: .dockBottom, screenFrame: screenFrame, visibleFrame: visibleFrame)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1440, height: 80))
    }

    func test_cgRect_无保留区返回nil() {
        // visibleFrame == screenFrame（无系统保留区）
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visible = frame
        XCTAssertNil(EdgeStripGeometry.cgRect(of: .menuBar, screenFrame: frame, visibleFrame: visible))
        XCTAssertNil(EdgeStripGeometry.cgRect(of: .dockBottom, screenFrame: frame, visibleFrame: visible))
    }
}
