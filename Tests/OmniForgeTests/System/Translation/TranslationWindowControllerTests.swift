import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

@MainActor
final class TranslationWindowControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var preferences: TranslationPreferences!
    private var store: InMemoryTranslationHistoryStore!
    private var engine: StubTranslationEngine!
    private var manager: TranslationManager!
    private var controller: TranslationWindowController!

    override func setUp() {
        super.setUp()
        suiteName = "TranslationWindowControllerTests-\(UUID().uuidString)"
        defaults = makeTranslationTestDefaults(suiteName)
        preferences = TranslationPreferences(userDefaults: defaults)
        store = InMemoryTranslationHistoryStore()
        engine = StubTranslationEngine()
        manager = makeTranslationTestManager(preferences: preferences, store: store, engine: engine)
        controller = TranslationWindowController(
            manager: manager,
            preferences: preferences,
            stringsProvider: { .en }
        )
        manager.windowPresenter = controller
    }

    override func tearDown() {
        controller?.hide()
        controller = nil
        manager = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 面板为 private 可选存储：Mirror 取到的是 Optional，需再解包一次。
    private func panel() -> NSPanel? {
        guard let controller else { return nil }
        let controllerMirror = Mirror(reflecting: controller)
        guard let stored = controllerMirror.children.first(where: { $0.label == "panel" }) else {
            return nil
        }
        return Mirror(reflecting: stored.value).children.first?.value as? NSPanel
    }

    func test_repeatedShowReusesWindow() {
        controller.show(focusInput: false)
        let first = panel()
        controller.show(focusInput: true)
        let second = panel()

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "进程内只保留一个翻译浮窗")
        XCTAssertEqual(first?.minSize, TranslationWindowController.minimumSize)
    }

    func test_defaultSizeAndMinimumSizeContract() {
        XCTAssertEqual(TranslationWindowController.defaultSize, NSSize(width: 600, height: 520))
        XCTAssertEqual(TranslationWindowController.minimumSize, NSSize(width: 440, height: 380))
    }

    func test_offscreenFrameIsRestoredVisibly() {
        preferences.saveWindowFrame(NSRect(x: 0, y: -5000, width: 600, height: 520))

        controller.show(focusInput: false)

        guard let frame = panel()?.frame else {
            return XCTFail("翻译浮窗未创建")
        }
        let isVisible = NSScreen.screens.contains { screen in
            let intersection = frame.intersection(screen.visibleFrame)
            return !intersection.isNull
                && intersection.width >= 50
                && intersection.height >= 50
        }
        XCTAssertTrue(isVisible, "离屏 frame 必须回落到可见区域，实际 \(frame)")
    }

    func test_hidePreservesSession() {
        manager.updateText("会话草稿")
        controller.show(focusInput: true)

        controller.hide()

        XCTAssertEqual(manager.sourceText, "会话草稿", "隐藏窗口必须保留本次会话")
        if case .translating = manager.phase {
            XCTFail("隐藏后不得仍处于翻译中")
        }
        XCTAssertEqual(manager.phase, .idle)
    }

    func test_closeAndEscHideKeepWindowReusable() {
        controller.show(focusInput: false)
        controller.hide()
        controller.show(focusInput: false)

        XCTAssertEqual(panel()?.isVisible, true)
    }

    func test_savedFramePersistsAcrossShowHide() {
        controller.show(focusInput: false)
        guard let frame = panel()?.frame else {
            return XCTFail("翻译浮窗未创建")
        }
        controller.hide()

        XCTAssertEqual(preferences.loadWindowFrame(), frame)
    }

    func test_headerSafeAreaAndTrafficLightsAlignment() {
        controller.show(focusInput: false)
        guard let panel = panel() else {
            return XCTFail("翻译浮窗未创建")
        }
        panel.contentView?.superview?.layoutSubtreeIfNeeded()

        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(panel.minSize, TranslationWindowController.minimumSize)
        XCTAssertEqual(panel.frame.size, TranslationWindowController.defaultSize)

        if let host = panel.contentViewController as? NSHostingController<AnyView> {
            XCTAssertTrue(host.safeAreaRegions.isEmpty, "必须清空 safeAreaRegions 避免自绘顶栏被下推")
        } else {
            XCTFail("contentViewController 应为 NSHostingController<AnyView>")
        }

        if let closeButton = panel.standardWindowButton(.closeButton) {
            let rectInWindow = closeButton.convert(closeButton.bounds, to: nil)
            let centerFromTop = panel.frame.height - rectInWindow.midY
            XCTAssertEqual(
                centerFromTop,
                18,
                accuracy: 4.0,
                "红绿灯垂直中心应与自绘顶栏控件中心（18pt）同行对齐"
            )
        }
    }
}
