import XCTest
@testable import OmniForge

@MainActor
final class PinnedScreenshotMenuBuilderTests: XCTestCase {
    final class FakeTarget: NSObject {
        @objc func copy(_ sender: Any?) {}
        @objc func save(_ sender: Any?) {}
        @objc func toggleClickThrough(_ sender: Any?) {}
        @objc func toggleLock(_ sender: Any?) {}
        @objc func close(_ sender: Any?) {}
        @objc func closeAll() {}
    }

    func test_buildMenu_empty_showsDisabledPlaceholder() {
        let target = FakeTarget()
        let menu = PinnedScreenshotMenuBuilder.buildMenu(
            handles: [],
            strings: .en,
            target: target,
            copySelector: #selector(FakeTarget.copy(_:)),
            saveSelector: #selector(FakeTarget.save(_:)),
            toggleClickThroughSelector: #selector(FakeTarget.toggleClickThrough(_:)),
            toggleLockSelector: #selector(FakeTarget.toggleLock(_:)),
            closeSelector: #selector(FakeTarget.close(_:)),
            closeAllSelector: #selector(FakeTarget.closeAll)
        )
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].title, Strings.en.pinnedMenuEmpty)
        XCTAssertFalse(menu.items[0].isEnabled)
    }

    func test_buildMenu_listsHandlesWithIndependentLockAndClickThroughActions() {
        let target = FakeTarget()
        let id = UUID()
        let handle = PinnedScreenshotHandle(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            isLocked: true,
            isClickThrough: true,
            opacity: 1,
            scale: 1,
            pixelWidth: 100,
            pixelHeight: 50
        )
        let menu = PinnedScreenshotMenuBuilder.buildMenu(
            handles: [handle],
            strings: .en,
            target: target,
            copySelector: #selector(FakeTarget.copy(_:)),
            saveSelector: #selector(FakeTarget.save(_:)),
            toggleClickThroughSelector: #selector(FakeTarget.toggleClickThrough(_:)),
            toggleLockSelector: #selector(FakeTarget.toggleLock(_:)),
            closeSelector: #selector(FakeTarget.close(_:)),
            closeAllSelector: #selector(FakeTarget.closeAll)
        )

        // 1 pin + separator + close all
        XCTAssertEqual(menu.items.count, 3)
        let pinItem = menu.items[0]
        XCTAssertTrue(pinItem.title.contains("100×50"))
        let sub = pinItem.submenu
        XCTAssertNotNil(sub)
        let titles = sub?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains(Strings.en.pinnedMenuCopy))
        XCTAssertTrue(titles.contains(Strings.en.pinnedMenuSave))
        XCTAssertTrue(titles.contains(Strings.en.pinnedMenuDisableClickThrough))
        XCTAssertTrue(titles.contains(Strings.en.pinnedMenuUnlock))
        XCTAssertTrue(titles.contains(Strings.en.pinnedMenuClose))
        XCTAssertEqual(menu.items.last?.title, Strings.en.pinnedMenuCloseAll)

        let copy = sub?.items.first { $0.title == Strings.en.pinnedMenuCopy }
        let ref = copy?.representedObject as? PinnedScreenshotMenuBuilder.PinActionRef
        XCTAssertEqual(ref?.id, id)
    }

    func test_buildMenu_unlockedNoClickThrough_usesEnableAndLockLabels() {
        let target = FakeTarget()
        let handle = PinnedScreenshotHandle(
            id: UUID(),
            createdAt: Date(),
            isLocked: false,
            isClickThrough: false,
            opacity: 1,
            scale: 1,
            pixelWidth: 10,
            pixelHeight: 10
        )
        let menu = PinnedScreenshotMenuBuilder.buildMenu(
            handles: [handle],
            strings: .zhHans,
            target: target,
            copySelector: #selector(FakeTarget.copy(_:)),
            saveSelector: #selector(FakeTarget.save(_:)),
            toggleClickThroughSelector: #selector(FakeTarget.toggleClickThrough(_:)),
            toggleLockSelector: #selector(FakeTarget.toggleLock(_:)),
            closeSelector: #selector(FakeTarget.close(_:)),
            closeAllSelector: #selector(FakeTarget.closeAll)
        )
        let titles = menu.items[0].submenu?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains(Strings.zhHans.pinnedMenuEnableClickThrough))
        XCTAssertTrue(titles.contains(Strings.zhHans.pinnedMenuLock))
    }
}
