import AppKit
import XCTest
@testable import OmniForge

/// 便签窗口选中态层级：窗口成为 key（含调度中心等系统代选路径）时临时抬升，
/// 失焦回落；置顶便签恒为 floating。
@MainActor
final class StickyNoteWindowControllerTests: XCTestCase {
    private var controllers: [StickyNoteWindowController] = []

    override func tearDown() {
        for controller in controllers {
            controller.close()
        }
        controllers.removeAll()
        super.tearDown()
    }

    // MARK: - 未置顶便签

    func test_becomeKey_promotesUnpinnedNoteLevel() {
        let controller = makeController(note: StickyNote())
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }

        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(controller.isSelectionPromoted)

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertTrue(controller.isSelectionPromoted)
        XCTAssertEqual(panel.level, StickyNoteWindowLevelPolicy.selectionPromotedLevel)
        XCTAssertFalse(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "选中态只抬层级，不得变成跨 Space 的事实置顶"
        )
    }

    func test_resignKey_withoutUserInput_keepsPromotedLevel() {
        let controller = makeController(note: StickyNote())
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        // 调度中心退场：系统把前台还给原应用导致过渡性失焦，期间没有任何
        // 用户输入（诊断日志 2026-11-09 实证：becomeKey 后约 250ms 无鼠标
        // 事件即 resignKey）。该失焦不得撤销抬升，否则便签被原窗口重新覆盖。
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertTrue(controller.isSelectionPromoted)
        XCTAssertEqual(panel.level, StickyNoteWindowLevelPolicy.selectionPromotedLevel)
    }

    func test_demoteSelection_restoresNormalLevel() {
        let controller = makeController(note: StickyNote())
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        // 用户点击便签以外的窗口：撤销抬升，恢复「可被其他窗口遮挡」语义。
        controller.demoteSelection()

        XCTAssertFalse(controller.isSelectionPromoted)
        XCTAssertEqual(panel.level, .normal)
    }

    func test_hide_resetsSelectionPromoted() {
        let controller = makeController(note: StickyNote())
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        controller.hide()

        XCTAssertFalse(controller.isSelectionPromoted, "隐藏即退出选中态，下次 show 不得带出旧抬升层级")
    }

    func test_repeatedBecomeKey_keepsPromotedLevel() {
        let controller = makeController(note: StickyNote())
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertTrue(controller.isSelectionPromoted)
        XCTAssertEqual(panel.level, StickyNoteWindowLevelPolicy.selectionPromotedLevel)
    }

    // MARK: - 置顶便签

    func test_pinnedNoteStaysFloatingWhenSelected() {
        let controller = makeController(note: StickyNote(pinned: true))
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }

        XCTAssertEqual(panel.level, .floating)

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(panel.level, .floating, "置顶便签层级不受选中态影响")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    // MARK: - 置顶切换与选中态叠加

    func test_unpinningWhileSelected_keepsPromotedLevel() {
        var note = StickyNote(pinned: true)
        let controller = makeController(note: note)
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        note.pinned = false
        controller.apply(note: note)

        XCTAssertTrue(controller.isSelectionPromoted)
        XCTAssertEqual(
            panel.level,
            StickyNoteWindowLevelPolicy.selectionPromotedLevel,
            "取消置顶时仍处于选中态：应回到抬升层级而不是普通层级"
        )
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func test_pinningWhileSelected_usesFloatingLevel() {
        var note = StickyNote()
        let controller = makeController(note: note)
        guard let panel = panel(of: controller) else { return XCTFail("便签窗口未创建") }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        note.pinned = true
        controller.apply(note: note)

        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    // MARK: - Helpers

    private func makeController(note: StickyNote) -> StickyNoteWindowController {
        let controller = StickyNoteWindowController(
            note: note,
            actionsProvider: { .noop },
            stringsProvider: { .en }
        )
        controllers.append(controller)
        return controller
    }

    /// `panel` 为 private 存储：Mirror 读取（与 TranslationWindowControllerTests 同一先例）。
    private func panel(of controller: StickyNoteWindowController) -> StickyNoteKeyablePanel? {
        let mirror = Mirror(reflecting: controller)
        guard let stored = mirror.children.first(where: { $0.label == "panel" }) else { return nil }
        return stored.value as? StickyNoteKeyablePanel
    }
}
