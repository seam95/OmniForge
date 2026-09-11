import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 设置窗口 chrome 高度稳定性契约。
///
/// 背景：SwiftUI 在工具栏**一个 item 都没有**时会把整个工具栏移除，标题栏高度会从
/// 52pt 掉到 28pt。若某个设置页独占工具栏内容（例如把该页的按钮放进 `.toolbar`），
/// 切到其他页面标题栏就会跳变 24pt、内容区反向跳变，观感像整页位移。
///
/// 因此约定：设置的页面级操作一律留在页内内容区，不放进窗口工具栏；本测试锁住
/// 「跨页切换时标题栏与内容区高度恒定」这一不变量，防止将来有人再往工具栏塞页面级内容。
@MainActor
final class SettingsChromeHeightStabilityTests: XCTestCase {

    /// 标题栏容器高度（内容区之上的 chrome）。
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

    func test_chromeHeightStaysStableAcrossPageSwitches() {
        let state = makeStateForObservation()
        let nav = SettingsNavigationModel()
        let hosting = NSHostingController(rootView: SettingsView(state: state, navigation: nav))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.orderFrontRegardless()

        var titlebars: [SettingsToolbarTab: CGFloat] = [:]
        var contents: [SettingsToolbarTab: CGFloat] = [:]

        // 特性页是曾经把按钮放进工具栏的页面，必须与其他页表现一致。
        for tab in [SettingsToolbarTab.features, .general, .features, .performance] {
            nav.select(tab, isAvailable: { _ in true })
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.9))
            window.contentView?.layoutSubtreeIfNeeded()
            if let h = titlebarHeight(window) { titlebars[tab] = h }
            contents[tab] = window.contentView?.frame.height ?? -1
        }

        let distinctTitlebars = Set(titlebars.values.map { ($0 / 2).rounded() })
        XCTAssertEqual(
            distinctTitlebars.count, 1,
            "标题栏高度必须跨页恒定，实测 \(titlebars.mapValues { String(format: "%.1f", $0) })"
        )
        let distinctContents = Set(contents.values.map { ($0 / 2).rounded() })
        XCTAssertEqual(
            distinctContents.count, 1,
            "内容区高度必须跨页恒定，实测 \(contents.mapValues { String(format: "%.1f", $0) })"
        )
    }

    /// 页面级批量操作必须位于页内内容区，不得出现在窗口工具栏
    /// （否则会改变 chrome 高度——见类注释）。
    func test_featureHubDoesNotContributeToolbarContent() {
        let state = makeStateForObservation()
        let nav = SettingsNavigationModel()
        nav.select(.features, isAvailable: { _ in true })
        let hosting = NSHostingController(rootView: SettingsView(state: state, navigation: nav))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 560))
        window.orderFrontRegardless()
        hosting.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))

        XCTAssertNil(
            window.toolbar,
            "特性页不应向窗口工具栏贡献任何内容（批量操作应留在页内）"
        )
    }
}
