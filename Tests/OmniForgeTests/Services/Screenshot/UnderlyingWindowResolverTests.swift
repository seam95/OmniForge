import CoreGraphics
import XCTest
@testable import OmniForge

final class UnderlyingWindowResolverTests: XCTestCase {
    func test_topmost_returnsFirstContainingPoint_frontToBack() {
        let windows = [
            SnapWindowInfo(windowID: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0),
            SnapWindowInfo(windowID: 2, ownerPID: 20, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0),
        ]
        let hit = UnderlyingWindowResolver.topmost(
            at: CGPoint(x: 50, y: 50),
            in: windows,
            excludingOwnerPID: 1
        )
        XCTAssertEqual(hit?.windowID, 1)
        XCTAssertEqual(hit?.ownerPID, 10)
    }

    func test_topmost_skipsExcludedOwnerEvenIfFront() {
        let windows = [
            SnapWindowInfo(windowID: 9, ownerPID: 99, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), layer: 0),
            SnapWindowInfo(windowID: 2, ownerPID: 20, bounds: CGRect(x: 0, y: 0, width: 400, height: 400), layer: 0),
        ]
        let hit = UnderlyingWindowResolver.topmost(
            at: CGPoint(x: 50, y: 50),
            in: windows,
            excludingOwnerPID: 99
        )
        XCTAssertEqual(hit?.windowID, 2)
    }

    func test_topmost_skipsNonContainingFrontWindow() {
        // 上层只盖住左侧，点在右侧 → 命中下层
        let windows = [
            SnapWindowInfo(windowID: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 0, width: 100, height: 200), layer: 0),
            SnapWindowInfo(windowID: 2, ownerPID: 20, bounds: CGRect(x: 0, y: 0, width: 400, height: 200), layer: 0),
        ]
        let hit = UnderlyingWindowResolver.topmost(
            at: CGPoint(x: 250, y: 50),
            in: windows,
            excludingOwnerPID: 1
        )
        XCTAssertEqual(hit?.windowID, 2)
    }

    func test_topmost_nilWhenNoWindowContainsPoint() {
        let windows = [
            SnapWindowInfo(windowID: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), layer: 0),
        ]
        let hit = UnderlyingWindowResolver.topmost(
            at: CGPoint(x: 500, y: 500),
            in: windows,
            excludingOwnerPID: 1
        )
        XCTAssertNil(hit)
    }

    func test_occludersInFrontOf_returnsOnlyEarlierWindows() {
        let windows = [
            SnapWindowInfo(windowID: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 0, width: 50, height: 50), layer: 0),
            SnapWindowInfo(windowID: 2, ownerPID: 20, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0),
            SnapWindowInfo(windowID: 3, ownerPID: 30, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), layer: 0),
        ]
        let front = UnderlyingWindowResolver.occluders(
            inFrontOf: windows[1],
            in: windows,
            excludingOwnerPID: 1
        )
        XCTAssertEqual(front.map(\.windowID), [1])
    }

    func test_candidatesContaining_frontToBackAllHits() {
        // 菜单栏条带与下方应用窗：点在菜单 y 范围时两者都含点（前→后 [menu, app]）；
        // 点在仅应用区时只有 app。
        let menu = SnapWindowInfo(
            windowID: 1, ownerPID: 11,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 24),
            layer: Int(CGWindowLevelForKey(.mainMenuWindow))
        )
        let app = SnapWindowInfo(
            windowID: 2, ownerPID: 22,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            layer: 0
        )
        let onMenuBand = UnderlyingWindowResolver.candidatesContaining(
            CGPoint(x: 100, y: 10),
            in: [menu, app],
            excludingOwnerPID: 1
        )
        XCTAssertEqual(onMenuBand.map(\.windowID), [1, 2])

        let onAppOnly = UnderlyingWindowResolver.candidatesContaining(
            CGPoint(x: 100, y: 100),
            in: [menu, app],
            excludingOwnerPID: 1
        )
        XCTAssertEqual(onAppOnly.map(\.windowID), [2])
    }

    /// 系统 UI 窗口（Dock/菜单栏/状态项，layer ≥ 20）不作为 app 候选的遮挡。
    /// 否则 Dock 全屏事件层会把 app 候选整块裁空。
    func test_occluders排除系统UI窗口() {
        let dock = SnapWindowInfo(
            windowID: 1, ownerPID: 10,
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),  // 全屏事件层
            layer: Int(CGWindowLevelForKey(.dockWindow))           // 20
        )
        let menu = SnapWindowInfo(
            windowID: 2, ownerPID: 11,
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 24),
            layer: Int(CGWindowLevelForKey(.mainMenuWindow))       // 24
        )
        let frontApp = SnapWindowInfo(
            windowID: 3, ownerPID: 30,
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            layer: 0
        )
        let backApp = SnapWindowInfo(
            windowID: 4, ownerPID: 40,
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            layer: 0
        )
        // backApp 前方有 dock / menu / frontApp，但只有 frontApp（layer 0）算遮挡。
        let occ = UnderlyingWindowResolver.occluders(
            inFrontOf: backApp,
            in: [dock, menu, frontApp, backApp],
            excludingOwnerPID: 1
        )
        XCTAssertEqual(occ.map(\.windowID), [3])  // 仅 frontApp，不含 dock/menu
    }
}
