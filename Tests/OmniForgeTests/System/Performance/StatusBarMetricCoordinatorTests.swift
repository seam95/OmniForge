import XCTest
import AppKit
@testable import OmniForge

final class StatusBarMetricCoordinatorTests: XCTestCase {
    /// 无 WindowServer 环境下用裸 NSStatusItem，避免 NSStatusBar.system 崩溃。
    private func makeCoordinator(sink: FakeStatusItemSink) -> StatusBarMetricCoordinator {
        StatusBarMetricCoordinator(
            sink: sink,
            makeItem: { NSStatusItem() },
            removeItem: { _ in }
        )
    }

    func test_disablingMetricsRemovesMetricItemsButKeepsMainIcon() {
        let sink = FakeStatusItemSink()
        let coordinator = makeCoordinator(sink: sink)
        coordinator.apply(
            mergedTitle: NSAttributedString(string: ""),
            separateGroups: [],
            separate: true
        )
        XCTAssertTrue(sink.metricItems.isEmpty)
        XCTAssertTrue(sink.mainItemIsVisible)
    }

    func test_mergedModeKeepsMainVisibleAndClearsSeparateItems() {
        let sink = FakeStatusItemSink()
        // 先模拟有独立项
        let leftover = NSStatusItem()
        sink.metricItems = [leftover]

        let coordinator = makeCoordinator(sink: sink)
        let title = NSAttributedString(string: "CPU")
        coordinator.apply(
            mergedTitle: title,
            separateGroups: [title],
            separate: false,
            hideMainIcon: false
        )

        XCTAssertTrue(sink.metricItems.isEmpty, "合并模式必须移除所有独立状态项")
        XCTAssertTrue(sink.mainItemIsVisible)
    }

    func test_separateMode_reapplyKeepsItemCountStable() {
        let sink = FakeStatusItemSink()
        let coordinator = makeCoordinator(sink: sink)
        let g1 = NSAttributedString(string: "A")
        let g2 = NSAttributedString(string: "B")
        coordinator.apply(
            mergedTitle: NSAttributedString(string: ""),
            separateGroups: [g1, g2],
            separate: true
        )
        let firstCount = sink.metricItems.count
        let firstObjectIDs = sink.metricItems.map { ObjectIdentifier($0) }
        XCTAssertEqual(firstCount, 2)

        coordinator.apply(
            mergedTitle: NSAttributedString(string: ""),
            separateGroups: [g1, g2],
            separate: true
        )
        XCTAssertEqual(sink.metricItems.count, 2)
        XCTAssertEqual(sink.metricItems.map { ObjectIdentifier($0) }, firstObjectIDs)
    }
}

final class FakeStatusItemSink: StatusItemSink {
    var mainItemIsVisible = true
    var metricItems: [NSStatusItem] = []
}
