import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

@MainActor
final class CleanerViewLayoutTests: XCTestCase {
    func test_idleCleaner_keepsSplitAndFirstSidebarRowInsideHost() throws {
        JunkCleaner.shared.reset()

        let ordinaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let ordinaryHostingView = try mount(
            CleanerSplitLayoutHarness {
                Text("Initial settings detail")
            },
            in: ordinaryWindow
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        ordinaryHostingView.layoutSubtreeIfNeeded()
        try assertVisibleSplitLayout(in: ordinaryHostingView, context: "普通 detail")

        let cleanerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let cleanerHostingView = try mount(
            CleanerSplitLayoutHarness {
                CleanerContentView(
                    strings: .en,
                    layout: .settings,
                    readNotificationStatus: { completion in completion(.notDetermined) }
                )
                    .background(CleanerDetailProbe())
            },
            in: cleanerWindow
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        cleanerHostingView.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            cleanerHostingView.firstDescendant(withIdentifier: .cleanerDetail),
            "断言布局前必须确认空闲 CleanerView 已完成挂载"
        )
        try assertVisibleSplitLayout(in: cleanerHostingView, context: "Cleaner detail")
    }

    private func mount<Root: View>(
        _ rootView: Root,
        in window: NSWindow
    ) throws -> NSHostingView<Root> {
        let contentView = try XCTUnwrap(window.contentView)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        return hostingView
    }

    private func assertVisibleSplitLayout(in hostView: NSView, context: String) throws {
        let splitView = try XCTUnwrap(
            hostView.descendants(of: NSSplitView.self).max {
                $0.frame.width < $1.frame.width
            },
            "\(context)：820×560 宿主中必须存在 NavigationSplitView 对应的真实 NSSplitView"
        )
        let splitFrame = splitView.convert(splitView.bounds, to: hostView)
        let hostBounds = hostView.bounds

        XCTAssertGreaterThanOrEqual(
            splitFrame.minY,
            hostBounds.minY,
            "\(context)：分栏根视图不应产生负原点；split=\(splitFrame), host=\(hostBounds)"
        )
        XCTAssertLessThanOrEqual(
            splitFrame.maxY,
            hostBounds.maxY,
            "\(context)：分栏根视图不应高于宿主；split=\(splitFrame), host=\(hostBounds)"
        )

        let firstRow = try XCTUnwrap(
            hostView.firstDescendant(withIdentifier: .cleanerSidebarFirstRow),
            "\(context)：侧栏首行的 AppKit 探针必须完成布局"
        )
        let firstRowFrame = firstRow.convert(firstRow.bounds, to: hostView)
        XCTAssertTrue(
            hostBounds.contains(firstRowFrame),
            "\(context)：侧栏首行必须位于宿主可视区域；row=\(firstRowFrame), host=\(hostBounds)"
        )
    }
}

private struct CleanerSplitLayoutHarness<Detail: View>: View {
    let detail: Detail
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(@ViewBuilder detail: () -> Detail) {
        self.detail = detail()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                SidebarFirstRowProbe()
                    .frame(height: 20)
                ForEach(1..<9) { index in
                    Text("Sidebar row \(index)")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: { detail }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 480, idealHeight: 560)
    }
}

private struct SidebarFirstRowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .cleanerSidebarFirstRow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct CleanerDetailProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .cleanerDetail
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension NSUserInterfaceItemIdentifier {
    static let cleanerDetail = NSUserInterfaceItemIdentifier(
        "CleanerViewLayoutTests.cleanerDetail"
    )
    static let cleanerSidebarFirstRow = NSUserInterfaceItemIdentifier(
        "CleanerViewLayoutTests.sidebarFirstRow"
    )
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? subview.descendants(of: type)
        }
    }

    func firstDescendant(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> NSView? {
        for subview in subviews {
            if subview.identifier == identifier {
                return subview
            }
            if let match = subview.firstDescendant(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
