import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 回归：特性页开关切换后，Form 滚动位置不得回顶。
/// 曾因 FeatureHubView 根部挂 .id(runtime.revision)，而 revision 在每次
/// availability 事务后自增，导致整棵 Form 连同滚动容器销毁重建、偏移归零。
@MainActor
final class FeatureHubScrollRetentionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // availability 直接写 standard（与 FeatureRuntime 既有测试同口径），
        // 并拦截 bindings，隔离布局测试与真实 Manager 副作用。
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.overrideBindingsForTesting { _ in }
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        super.tearDown()
    }

    func test_uninstallFeature_keepsFormScrollOffset() throws {
        let host = try mountFeatureHub()
        let scrollView = try scrollableForm(in: host)

        // 模拟用户浏览到列表底部
        scrollToBottom(scrollView)
        settle()
        let offsetBefore = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(offsetBefore, 0, "预置：滚动后必须离开顶部")
        let maxOffset = maxScrollOffset(scrollView)
        XCTAssertLessThanOrEqual(
            offsetBefore, maxOffset + 1,
            "预置：滚动偏移须被约束在文档范围内（当前 max=\(maxOffset)）"
        )

        FeatureRuntime.shared.setAvailable(.clipboardHistory, false)
        settleForRebuild()

        // 开关状态须随重绘正确翻转（重绘由 @ObservedObject 驱动，不依赖 .id 重建）
        XCTAssertEqual(
            host.descendants(of: NSSwitch.self).filter { $0.state == .on }.count,
            AppFeature.allCases.count - 1,
            "卸载后对应 Toggle 须翻转为 off"
        )

        // .id 重建会替换滚动容器实例，须重新定位后再取偏移
        let scrollViewAfter = try scrollableForm(in: host)
        let offsetAfter = scrollViewAfter.contentView.bounds.origin.y
        XCTAssertGreaterThan(
            offsetAfter,
            offsetBefore - 20,
            "卸载特性后滚动位置回顶：before=\(offsetBefore) after=\(offsetAfter)"
        )
    }

    func test_installFeature_keepsFormScrollOffset() throws {
        UserDefaults.standard.set(false, forKey: AppFeature.cleaningMode.availabilityKey)
        FeatureRuntime.shared.resetForTesting()

        let host = try mountFeatureHub()
        let scrollView = try scrollableForm(in: host)

        scrollToBottom(scrollView)
        settle()
        let offsetBefore = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(offsetBefore, 0, "预置：滚动后必须离开顶部")

        FeatureRuntime.shared.setAvailable(.cleaningMode, true)
        settleForRebuild()

        // 开关状态须随重绘正确翻转（重绘由 @ObservedObject 驱动，不依赖 .id 重建）
        XCTAssertEqual(
            host.descendants(of: NSSwitch.self).filter { $0.state == .on }.count,
            AppFeature.allCases.count,
            "安装后对应 Toggle 须翻转为 on"
        )

        let scrollViewAfter = try scrollableForm(in: host)
        let offsetAfter = scrollViewAfter.contentView.bounds.origin.y
        XCTAssertGreaterThan(
            offsetAfter,
            offsetBefore - 20,
            "安装特性后滚动位置回顶：before=\(offsetBefore) after=\(offsetAfter)"
        )
    }

    // MARK: - harness

    private func mountFeatureHub() throws -> NSHostingView<FeatureHubView> {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        let hostingView = NSHostingView(rootView: FeatureHubView(l10n: L10n()))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        settle()
        hostingView.layoutSubtreeIfNeeded()
        return hostingView
    }

    /// 定位 grouped Form 底层的 NSScrollView，并校验内容确实超出视口。
    private func scrollableForm(in host: NSView) throws -> NSScrollView {
        let scrollView = try XCTUnwrap(
            host.descendants(of: NSScrollView.self).first,
            "grouped Form 底层必须存在可操作的 NSScrollView"
        )
        let documentHeight = try XCTUnwrap(
            scrollView.contentView.documentView,
            "Form 滚动容器必须有 documentView"
        ).frame.height
        XCTAssertGreaterThan(
            documentHeight,
            scrollView.contentView.bounds.height,
            "特性列表内容须超出视口，否则滚动保持断言无意义"
        )
        return scrollView
    }

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
    }

    /// availability 事务后的 .id 重建跨越销毁/新建两个阶段，等待须长于普通布局。
    private func settleForRebuild() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: 0, y: maxScrollOffset(scrollView)))
    }

    private func maxScrollOffset(_ scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        return max(0, clip.documentRect.height - clip.bounds.height)
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? subview.descendants(of: type)
        }
    }
}
