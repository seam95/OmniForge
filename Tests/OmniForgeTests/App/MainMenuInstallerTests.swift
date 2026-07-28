import XCTest
@testable import OmniForge

@MainActor
final class MainMenuInstallerTests: XCTestCase {

    /// 菜单测试用假目标：须实现 `MainMenuSettingsTarget` 全部 selector。
    private final class FakeTarget: NSObject {
        @objc func openSettings() {}
        @objc func openShelf() {}
        @objc func captureScreenshotAllInOne() {}
        @objc func captureScreenshotFullscreen() {}
    }

    func test_makeMenu_hasAppMenuWithQuit() {
        let menu = MainMenuInstaller.makeMenu(target: nil, strings: .en)

        let appMenuItem = menu.item(at: 0)
        XCTAssertNotNil(appMenuItem)
        let appMenu = appMenuItem?.submenu
        XCTAssertNotNil(appMenu)

        let quitItem = appMenu?.items.first { $0.keyEquivalent == "q" }
        XCTAssertNotNil(quitItem)
        XCTAssertEqual(quitItem?.keyEquivalentModifierMask, .command)
    }

    func test_makeMenu_hasEditMenuWithCopyPaste() {
        let menu = MainMenuInstaller.makeMenu(target: nil, strings: .en)

        let editMenuItem = menu.item(at: 1)
        XCTAssertNotNil(editMenuItem)
        let editMenu = editMenuItem?.submenu
        XCTAssertNotNil(editMenu)

        let copyItem = editMenu?.items.first { $0.keyEquivalent == "c" }
        XCTAssertNotNil(copyItem)
        let pasteItem = editMenu?.items.first { $0.keyEquivalent == "v" }
        XCTAssertNotNil(pasteItem)
        let cutItem = editMenu?.items.first { $0.keyEquivalent == "x" }
        XCTAssertNotNil(cutItem)
        let selectAllItem = editMenu?.items.first { $0.keyEquivalent == "a" }
        XCTAssertNotNil(selectAllItem)
    }

    func test_makeMenu_hasWindowMenuWithMinimize() {
        let menu = MainMenuInstaller.makeMenu(target: nil, strings: .en)

        let windowMenuItem = menu.item(at: 2)
        XCTAssertNotNil(windowMenuItem)
        let windowMenu = windowMenuItem?.submenu
        XCTAssertNotNil(windowMenu)

        let minimizeItem = windowMenu?.items.first { $0.keyEquivalent == "m" }
        XCTAssertNotNil(minimizeItem)
        let closeItem = windowMenu?.items.first { $0.keyEquivalent == "w" }
        XCTAssertNotNil(closeItem)
    }

    func test_makeMenu_settingsTargetsProvidedObject() {
        let target = FakeTarget()
        let menu = MainMenuInstaller.makeMenu(target: target, strings: .en)

        let appMenu = menu.item(at: 0)?.submenu
        let settingsItem = appMenu?.items.first { $0.keyEquivalent == "," }
        XCTAssertNotNil(settingsItem)
        XCTAssertEqual(settingsItem?.target as? FakeTarget, target)
        XCTAssertEqual(settingsItem?.action, #selector(FakeTarget.openSettings))
    }

    func test_makeMenu_hasOpenShelfAfterSettings() {
        let target = FakeTarget()
        let menu = MainMenuInstaller.makeMenu(target: target, strings: .en)
        let appMenu = menu.item(at: 0)?.submenu
        let shelfItem = appMenu?.items.first { $0.title == Strings.en.shelfMenuItem }
        XCTAssertNotNil(shelfItem)
        XCTAssertEqual(shelfItem?.action, #selector(FakeTarget.openShelf))
        XCTAssertEqual(shelfItem?.target as? FakeTarget, target)

        let settingsIndex = appMenu?.items.firstIndex { $0.keyEquivalent == "," }
        let shelfIndex = appMenu?.items.firstIndex { $0.title == Strings.en.shelfMenuItem }
        XCTAssertNotNil(settingsIndex)
        XCTAssertNotNil(shelfIndex)
        if let settingsIndex, let shelfIndex {
            XCTAssertEqual(shelfIndex, settingsIndex + 1)
        }
    }

    func test_makeMenu_hasScreenshotSubmenuWithAllInOneAndFullscreen() {
        let target = FakeTarget()
        let s = Strings.en
        let menu = MainMenuInstaller.makeMenu(target: target, strings: s)
        let appMenu = menu.item(at: 0)?.submenu
        let root = appMenu?.items.first { $0.title == s.screenshotMenuTitle }
        XCTAssertNotNil(root)
        let sub = root?.submenu
        XCTAssertEqual(sub?.items.count, 2)
        XCTAssertEqual(sub?.items[0].title, s.screenshotHotkeyAllInOne)
        XCTAssertEqual(sub?.items[0].action, #selector(FakeTarget.captureScreenshotAllInOne))
        XCTAssertEqual(sub?.items[1].title, s.screenshotHotkeyFullscreen)
        XCTAssertEqual(sub?.items[1].action, #selector(FakeTarget.captureScreenshotFullscreen))
        for item in sub?.items ?? [] {
            XCTAssertEqual(item.target as? FakeTarget, target)
            XCTAssertEqual(item.keyEquivalent, "")
        }

        let shelfIndex = appMenu?.items.firstIndex { $0.title == s.shelfMenuItem }
        let shotIndex = appMenu?.items.firstIndex { $0.title == s.screenshotMenuTitle }
        XCTAssertNotNil(shelfIndex)
        XCTAssertNotNil(shotIndex)
        if let shelfIndex, let shotIndex {
            XCTAssertEqual(shotIndex, shelfIndex + 1)
        }
    }

    func test_makeMenu_allInOneLabel_localizedChinese() {
        let target = FakeTarget()
        let s = Strings.zhHans
        let menu = MainMenuInstaller.makeMenu(target: target, strings: s)
        let appMenu = menu.item(at: 0)?.submenu
        let root = appMenu?.items.first { $0.title == s.screenshotMenuTitle }
        let first = root?.submenu?.items.first
        XCTAssertEqual(first?.title, "全能截图")
        XCTAssertEqual(first?.action, #selector(FakeTarget.captureScreenshotAllInOne))
    }
}
