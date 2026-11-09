import AppKit
import XCTest
@testable import OmniForge

/// 便签注册表的用户交互降级：点击便签以外的窗口撤销选中态抬升，
/// 点击便签自身（切换选中另一张）只降其余便签。
@MainActor
final class StickyNoteWindowRegistryTests: XCTestCase {
    private var registry: StickyNoteWindowRegistry!

    override func tearDown() {
        registry?.dismissAll()
        registry = nil
        super.tearDown()
    }

    private func makeRegistry() -> StickyNoteWindowRegistry {
        StickyNoteWindowRegistry(stringsProvider: { .en })
    }

    /// `controllers` 为 private 存储：Mirror 读取（与 ControllerTests 的 panel 先例一致）。
    private func controllers(of registry: StickyNoteWindowRegistry) -> [StickyNoteWindowController] {
        let mirror = Mirror(reflecting: registry)
        guard let stored = mirror.children.first(where: { $0.label == "controllers" }),
              let map = stored.value as? [UUID: StickyNoteWindowController] else { return [] }
        return Array(map.values)
    }

    func test_userClickOutsideNote_demotesSelection() {
        registry = makeRegistry()
        let note = StickyNote(content: "选中态便签")
        registry.show(note: note)
        guard let controller = controllers(of: registry).first else { return XCTFail("便签窗口未创建") }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(controller.isSelectionPromoted)

        // 用户点击其他应用 / 本应用其他窗口：windowNumber 不属于任何便签。
        registry.handleUserMouseDown(windowNumber: controller.windowNumber + 1)

        XCTAssertFalse(controller.isSelectionPromoted, "点击便签以外的窗口必须撤销抬升")
    }

    func test_userClickOnNote_keepsItsSelectionAndDemotesOthers() {
        registry = makeRegistry()
        var first = StickyNote(content: "第一张")
        let second = StickyNote(content: "第二张")
        first.frame.origin.x += 400
        registry.show(note: first)
        registry.show(note: second)
        let controllers = self.controllers(of: registry)
        guard controllers.count == 2 else { return XCTFail("应创建两个便签窗口") }
        let clicked = controllers[0]
        let other = controllers[1]
        clicked.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        other.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        // 点击第一张便签：它保持选中，另一张回落普通层级。
        registry.handleUserMouseDown(windowNumber: clicked.windowNumber)

        XCTAssertTrue(clicked.isSelectionPromoted, "被点击的便签保持选中")
        XCTAssertFalse(other.isSelectionPromoted, "选中另一张便签时，原选中便签回落")
    }
}
