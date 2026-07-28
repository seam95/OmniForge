import OmniForge
@testable import OmniForge
import XCTest

final class SCWindowSnapProviderTests: XCTestCase {
    /// SCWindow 在测试中不可构造,用 stub 结构体模拟。
    private struct StubWindow {
        let frame: CGRect
        let windowID: CGWindowID
    }

    func test_单点命中返回该窗口() {
        let windows = [
            StubWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 400), windowID: 10)
        ]
        let hit = SCWindowPicker.topmostWindow(
            containing: CGPoint(x: 100, y: 100),
            in: windows.map { SCWindowLikeStub(frame: $0.frame, windowID: $0.windowID) }
        )
        XCTAssertEqual(hit?.windowID, 10)
    }

    func test_多点命中取数组首位即zorder顶层() {
        // windows 数组顺序 = z-order 从前到后,第一个命中的即顶层
        let windows = [
            StubWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 400), windowID: 10),
            StubWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 400), windowID: 20)  // 被遮挡
        ]
        let hit = SCWindowPicker.topmostWindow(
            containing: CGPoint(x: 250, y: 200),
            in: windows.map { SCWindowLikeStub(frame: $0.frame, windowID: $0.windowID) }
        )
        XCTAssertEqual(hit?.windowID, 10)
    }

    func test_顶层不包含该点返回下层() {
        let windows = [
            StubWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 10),  // 左上角小窗
            StubWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 20)   // 大窗
        ]
        // 点 (500, 300) 不在小窗内,在大窗内 → 命中大窗
        let hit = SCWindowPicker.topmostWindow(
            containing: CGPoint(x: 500, y: 300),
            in: windows.map { SCWindowLikeStub(frame: $0.frame, windowID: $0.windowID) }
        )
        XCTAssertEqual(hit?.windowID, 20)
    }

    func test_无命中返回nil() {
        let windows = [
            StubWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100), windowID: 10)
        ]
        let hit = SCWindowPicker.topmostWindow(
            containing: CGPoint(x: 500, y: 500),
            in: windows.map { SCWindowLikeStub(frame: $0.frame, windowID: $0.windowID) }
        )
        XCTAssertNil(hit)
    }

    func test_空列表返回nil() {
        let hit = SCWindowPicker.topmostWindow(containing: CGPoint(x: 0, y: 0), in: [SCWindowLikeStub]())
        XCTAssertNil(hit)
    }
}

/// 测试用 SCWindowLike 实现(因 SCWindow 无法在测试中构造)。
private struct SCWindowLikeStub: SCWindowLike {
    let frame: CGRect
    let windowID: CGWindowID
}
