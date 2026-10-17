import AppKit
import XCTest
@testable import OmniForge

/// 剪贴板面板关闭瞬间的窗口持焦抑制：掐灭便签承接 key window 导致的焦点滞留。
@MainActor
final class PanelKeySuppressionTests: XCTestCase {
    override func tearDown() {
        PanelKeySuppression.end()
    }

    func test_beginActivatesSuppression() {
        XCTAssertFalse(PanelKeySuppression.isActive)

        PanelKeySuppression.begin()

        XCTAssertTrue(PanelKeySuppression.isActive)
    }

    func test_endDeactivatesSuppressionImmediately() {
        PanelKeySuppression.begin()
        PanelKeySuppression.end()

        XCTAssertFalse(PanelKeySuppression.isActive)
    }

    func test_suppressionExpiresAfterInterval() {
        // 零间隔：begin 后立即到期（自愈语义的时钟边界）
        PanelKeySuppression.begin(interval: 0)

        // Date 精度下 0 间隔必然已过期（>= 截止时刻）
        RunLoop.main.run(until: Date())
        XCTAssertFalse(PanelKeySuppression.isActive)
    }

    func test_stickyPanelRefusesKeyWhileSuppressed() {
        let panel = StickyNoteKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 90)
        )
        defer { panel.close() }

        XCTAssertTrue(panel.canBecomeKey)

        PanelKeySuppression.begin()
        XCTAssertFalse(panel.canBecomeKey, "抑制期间便签不得承接 key window（否则粘贴错投便签）")

        PanelKeySuppression.end()
        XCTAssertTrue(panel.canBecomeKey, "抑制结束后便签必须恢复可聚焦（正常输入依赖）")
    }
}
