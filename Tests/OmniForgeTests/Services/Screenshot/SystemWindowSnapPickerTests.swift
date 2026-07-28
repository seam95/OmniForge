import CoreGraphics
import XCTest
@testable import OmniForge

/// SystemWindowSnapPicker 纯函数测试。
///
/// layer 常量：dock=20、mainMenu=24、status=25（CGWindowLevelForKey）。
final class SystemWindowSnapPickerTests: XCTestCase {
    private let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))      // 24
    private let statusLayer = Int(CGWindowLevelForKey(.statusWindow))         // 25
    private let dockLayer = Int(CGWindowLevelForKey(.dockWindow))             // 20

    private func window(id: CGWindowID, pid: pid_t, layer: Int, _ rect: CGRect) -> SnapWindowInfo {
        SnapWindowInfo(windowID: id, ownerPID: pid, bounds: rect, layer: layer)
    }

    /// 鼠标在状态项图标 bounds 内 → 返回该状态项窗口。
    func test_状态项命中返回该状态项() {
        let menuBar = window(id: 1, pid: 168, layer: menuBarLayer, CGRect(x: 0, y: 0, width: 1440, height: 24))
        let statusItem = window(id: 2, pid: 500, layer: statusLayer, CGRect(x: 900, y: 0, width: 38, height: 24))
        let pt = CGPoint(x: 910, y: 12)  // 在状态项内
        let pick = SystemWindowSnapPicker.pick(at: pt, in: [menuBar, statusItem])
        XCTAssertEqual(pick?.windowID, 2)
    }

    /// 鼠标在菜单栏非图标区 → 返回整条菜单栏。
    func test_菜单栏非图标区返回整条菜单栏() {
        let menuBar = window(id: 1, pid: 168, layer: menuBarLayer, CGRect(x: 0, y: 0, width: 1440, height: 24))
        let statusItem = window(id: 2, pid: 500, layer: statusLayer, CGRect(x: 900, y: 0, width: 38, height: 24))
        let pt = CGPoint(x: 200, y: 12)  // 菜单栏内但不在状态项上
        let pick = SystemWindowSnapPicker.pick(at: pt, in: [menuBar, statusItem])
        XCTAssertEqual(pick?.windowID, 1)
        XCTAssertEqual(pick?.bounds.width, 1440)
    }

    /// 多个状态项含同一点 → 返回面积最小者（细化）。
    func test_多个状态项含点返回面积最小者() {
        let big = window(id: 10, pid: 500, layer: statusLayer, CGRect(x: 800, y: 0, width: 200, height: 24))
        let small = window(id: 11, pid: 501, layer: statusLayer, CGRect(x: 850, y: 0, width: 38, height: 24))
        let pt = CGPoint(x: 860, y: 12)  // 两者都含
        let pick = SystemWindowSnapPicker.pick(at: pt, in: [big, small])
        XCTAssertEqual(pick?.windowID, 11)  // 面积最小
    }

    /// 鼠标在屏中央（无系统窗口含点）→ nil。
    func test_屏中央返回nil() {
        let menuBar = window(id: 1, pid: 168, layer: menuBarLayer, CGRect(x: 0, y: 0, width: 1440, height: 24))
        let pt = CGPoint(x: 720, y: 450)
        XCTAssertNil(SystemWindowSnapPicker.pick(at: pt, in: [menuBar]))
    }

    /// layer 20（Dock）含点 → 不被本选择器选中（返回 nil，交回 AX 路径）。
    func test_Dock窗口不被选中() {
        let dock = window(id: 5, pid: 448, layer: dockLayer, CGRect(x: 0, y: 0, width: 1440, height: 900))
        let pt = CGPoint(x: 40, y: 450)  // 左侧 Dock 区
        XCTAssertNil(SystemWindowSnapPicker.pick(at: pt, in: [dock]))
    }

    /// 菜单栏和状态项都含点时，状态项优先（即使菜单栏在前）。
    func test_状态项优先于菜单栏() {
        let menuBar = window(id: 1, pid: 168, layer: menuBarLayer, CGRect(x: 0, y: 0, width: 1440, height: 24))
        let statusItem = window(id: 2, pid: 500, layer: statusLayer, CGRect(x: 900, y: 0, width: 38, height: 24))
        let pt = CGPoint(x: 919, y: 12)
        // 两者都含点 → 状态项优先
        let pick = SystemWindowSnapPicker.pick(at: pt, in: [menuBar, statusItem])
        XCTAssertEqual(pick?.windowID, 2)
    }
}
