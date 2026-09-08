import CoreGraphics
import Foundation
import XCTest
@testable import OmniForge

/// AXWindowSnapProvider 自有进程窗口整窗直选回归。
///
/// 历史缺陷：窗口列表按 PID 整进程排除自身，控制中心/剪贴板/钉图等
/// 自有窗口永远无吸附候选。修复后仅排除遮罩面板（窗口 ID），
/// 自有窗口命中时跳过 AX、直接以窗口列表 bounds 为候选。
final class AXWindowSnapProviderSelfWindowTests: XCTestCase {
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    /// 视图坐标 (x, y) ↔ CG 全局 (x, 600 - y)；CG 矩形 y 为顶边。
    private let screen = NSRect(x: 0, y: 0, width: 800, height: 600)

    private func makeProvider(windows: [SnapWindowInfo]) -> AXWindowSnapProvider {
        AXWindowSnapProvider(windowListProvider: { windows })
    }

    private func candidate(
        _ provider: AXWindowSnapProvider,
        atViewPoint x: CGFloat, _ y: CGFloat
    ) async -> SnapCandidate? {
        await provider.candidate(
            at: NSPoint(x: x, y: y),
            in: screen,
            screenFrame: screen,
            visibleFrame: screen,
            primaryDisplayHeight: 600
        )
    }

    func test_自有窗口命中时整窗直选() async {
        let own = SnapWindowInfo(
            windowID: 7, ownerPID: selfPID,
            bounds: CGRect(x: 100, y: 100, width: 200, height: 150),
            layer: 0
        )
        let thirdParty = SnapWindowInfo(
            windowID: 2, ownerPID: 20,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            layer: 0
        )
        let provider = makeProvider(windows: [own, thirdParty])

        // 自有窗口中心：CG (200, 175) ↔ 视图 (200, 425)
        let result = await candidate(provider, atViewPoint: 200, 425)

        // CG (100, 100, 200, 150) → 视图 (100, 350, 200, 150)
        XCTAssertEqual(result?.rect, NSRect(x: 100, y: 350, width: 200, height: 150))
        XCTAssertEqual(result?.windowID, 7)
    }

    func test_自有窗口被前方第三方窗口遮挡时裁切可见区() async {
        let front = SnapWindowInfo(
            windowID: 5, ownerPID: 20,
            bounds: CGRect(x: 100, y: 100, width: 200, height: 100),
            layer: 0
        )
        let own = SnapWindowInfo(
            windowID: 7, ownerPID: selfPID,
            bounds: CGRect(x: 100, y: 100, width: 200, height: 150),
            layer: 0
        )
        let provider = makeProvider(windows: [front, own])

        // 自有窗口下半部：CG (200, 225) ↔ 视图 (200, 375)
        let result = await candidate(provider, atViewPoint: 200, 375)

        // 遮挡裁切后可见区 CG (100, 200, 200, 50) → 视图 (100, 350, 200, 50)
        XCTAssertEqual(result?.rect, NSRect(x: 100, y: 350, width: 200, height: 50))
        XCTAssertEqual(result?.windowID, 7)
    }

    func test_自有窗口不含点时回落第三方路径() async {
        let own = SnapWindowInfo(
            windowID: 7, ownerPID: selfPID,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            layer: 0
        )
        // pid 99999 不存在：AX hit-test 必失败 → 无候选（单测环境无法覆盖真实 AX 命中）
        let nonexistent = SnapWindowInfo(
            windowID: 2, ownerPID: 99999,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            layer: 0
        )
        let provider = makeProvider(windows: [own, nonexistent])

        let result = await candidate(provider, atViewPoint: 400, 300)
        XCTAssertNil(result)
    }

    func test_自有窗口小于最小边长时丢弃() async {
        let own = SnapWindowInfo(
            windowID: 7, ownerPID: selfPID,
            bounds: CGRect(x: 100, y: 100, width: 10, height: 10),
            layer: 0
        )
        let provider = makeProvider(windows: [own])

        // 窗口中心：CG (105, 105) ↔ 视图 (105, 495)
        let result = await candidate(provider, atViewPoint: 105, 495)
        XCTAssertNil(result)
    }
}
