import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 设置窗口工具栏恒定契约：SwiftUI 在工具栏一个 item 都没有时会把整个工具栏移除，
/// 标题栏高度从 52pt 掉到 28pt——特性页的「全部安装 / 全部卸载」只在该页存在，
/// 切到其他设置页会让标题栏跳变 24pt（内容区反向跳变，观感像整页位移）。
/// 这里在窗口根层放恒存在的占位 item 锁住高度，本测试即该行为的回归保护。
@MainActor
final class SettingsToolbarStabilityTests: XCTestCase {

    /// 标题栏容器高度（设置窗内容区之上的 chrome）。
    private func titlebarHeight(_ window: NSWindow) -> CGFloat? {
        guard let frameView = window.contentView?.superview else { return nil }
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("NSTitlebarContainerView") { return view }
            for sub in view.subviews {
                if let hit = find(sub) { return hit }
            }
            return nil
        }
        return find(frameView)?.frame.height
    }

    func test_titlebarHeightStaysStableAcrossPageSwitches() {
        let state = makeStateForObservation()
        let nav = SettingsNavigationModel()
        let hosting = NSHostingController(rootView: SettingsView(state: state, navigation: nav))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.orderFrontRegardless()

        var heights: [SettingsToolbarTab: CGFloat] = [:]
        var contentHeights: [SettingsToolbarTab: CGFloat] = [:]

        for tab in [SettingsToolbarTab.features, .general, .features, .performance] {
            nav.select(tab, isAvailable: { _ in true })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.9))
            window.contentView?.layoutSubtreeIfNeeded()
            if let h = titlebarHeight(window) { heights[tab] = h }
            contentHeights[tab] = window.contentView?.frame.height ?? -1

            XCTAssertNotNil(
                window.toolbar,
                "\(tab.rawValue) 页工具栏必须存在（否则标题栏高度会塌陷）"
            )
        }

        // 标题栏高度跨页恒定（容忍亚像素差异）。
        let distinct = Set(heights.values.map { ($0 / 2).rounded() })
        XCTAssertEqual(
            distinct.count, 1,
            "标题栏高度必须跨页恒定，实测 \(heights.mapValues { String(format: "%.1f", $0) })"
        )
        // 内容区高度同样不应跳变——这正是用户看到的"整页位移"。
        let distinctContent = Set(contentHeights.values.map { ($0 / 2).rounded() })
        XCTAssertEqual(
            distinctContent.count, 1,
            "内容区高度必须跨页恒定，实测 \(contentHeights.mapValues { String(format: "%.1f", $0) })"
        )
    }

    /// 占位自身不可见、不占据可感知空间（不得变成可见的空白按钮）。
    func test_reservationPlaceholderIsMinimalAndHidden() {
        XCTAssertEqual(SettingsToolbarReservation.placeholderSize, 1)
    }
}
