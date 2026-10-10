import XCTest
@testable import OmniForge

final class ClotheslineRevealStateMachineTests: XCTestCase {
    func testMenuBarBandUsesVisibleFrameGap() {
        // AppKit 左下原点：顶部留 30pt 给菜单栏 → visibleFrame.maxY = 970，
        // 条带高度取 frame.maxY - visibleFrame.maxY = 30。
        let screen = FakeScreen(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000),
                                visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 970))
        let band = ClotheslineCoordinator.menuBarBand(of: screen)
        XCTAssertEqual(band.height, 30)
        XCTAssertEqual(band.maxY, 1000)
    }

    func testMenuBarBandFallsBackToSystemThickness() {
        // 自动隐藏菜单栏：visibleFrame 顶到屏顶 → 用系统状态栏厚度与安全区上边距的较大者。
        // 注入 top=24（模拟带刘海屏）：NSStatusBar.thickness 随系统版本在 22/24 间浮动，
        // 仅靠它断言不稳定；max 语义由注入值兜底验证。
        let screen = FakeScreen(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000),
                                visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 1000),
                                safeAreaInsets: NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0))
        let band = ClotheslineCoordinator.menuBarBand(of: screen)
        XCTAssertGreaterThanOrEqual(band.height, 24)
    }

    func testHotZoneDecision() {
        let now = Date()
        // 菜单栏内停留 0.25s → 触发
        XCTAssertTrue(ClotheslineCoordinator.shouldRevealFromMenuBar(
            inMenuBar: true, suppressed: false, hotZoneSince: now.addingTimeInterval(-0.3), now: now))
        // 停留不足 → 不触发
        XCTAssertFalse(ClotheslineCoordinator.shouldRevealFromMenuBar(
            inMenuBar: true, suppressed: false, hotZoneSince: now.addingTimeInterval(-0.1), now: now))
        // 被菜单栏点击抑制 → 不触发
        XCTAssertFalse(ClotheslineCoordinator.shouldRevealFromMenuBar(
            inMenuBar: true, suppressed: true, hotZoneSince: now.addingTimeInterval(-1), now: now))
    }

    func testRetractDecision() {
        let now = Date()
        // 区内或忙碌 → 不收
        XCTAssertFalse(ClotheslineCoordinator.shouldRetract(
            inside: true, busy: true, awaySince: nil, now: now))
        XCTAssertFalse(ClotheslineCoordinator.shouldRetract(
            inside: false, busy: true, awaySince: now.addingTimeInterval(-5), now: now))
        // 区外 ≥0.5s → 收
        XCTAssertTrue(ClotheslineCoordinator.shouldRetract(
            inside: false, busy: false, awaySince: now.addingTimeInterval(-0.6), now: now))
        // 区外不足 → 不收
        XCTAssertFalse(ClotheslineCoordinator.shouldRetract(
            inside: false, busy: false, awaySince: now.addingTimeInterval(-0.2), now: now))
        XCTAssertFalse(ClotheslineCoordinator.shouldRetract(
            inside: false, busy: false, awaySince: nil, now: now))
    }

    func testFullScreenCheckScreenPrefersPanelScreen() {
        // 绳子所在屏优先（与参照实现一致）：绳在 A 屏时只看 A 屏的全屏状态，
        // 指针在 B 屏（无论 B 是否全屏）都不影响——否则 B 屏全屏会误收 A 屏的绳。
        let panelScreen = FakeScreen(frame: .zero, visibleFrame: .zero)
        let pointerScreen = FakeScreen(frame: .zero, visibleFrame: .zero)
        XCTAssertTrue(ClotheslineCoordinator.fullScreenCheckScreen(panelScreen: panelScreen,
                                                                   pointerScreen: pointerScreen) === panelScreen)
        // 面板无屏（未在场）才回退指针屏
        XCTAssertTrue(ClotheslineCoordinator.fullScreenCheckScreen(panelScreen: nil,
                                                                   pointerScreen: pointerScreen) === pointerScreen)
        // 两者皆无 → 不压制
        XCTAssertNil(ClotheslineCoordinator.fullScreenCheckScreen(panelScreen: nil, pointerScreen: nil))
    }
}

/// 测试用 NSScreen 替身：frame/visibleFrame/safeAreaInsets 可注入（类别覆写不可行，用轻量子类）。
/// safeAreaInsets 必须一并覆写：menuBarBand 回退分支读它，而基类实现
/// 依赖底层屏幕对象，纯数据子类实例上一访问即 trap。
private final class FakeScreen: NSScreen {
    private let f: NSRect
    private let v: NSRect
    private let i: NSEdgeInsets
    init(frame: NSRect, visibleFrame: NSRect, safeAreaInsets: NSEdgeInsets = NSEdgeInsets()) {
        self.f = frame
        self.v = visibleFrame
        self.i = safeAreaInsets
        super.init()
    }
    override var frame: NSRect { f }
    override var visibleFrame: NSRect { v }
    override var safeAreaInsets: NSEdgeInsets { i }
}
