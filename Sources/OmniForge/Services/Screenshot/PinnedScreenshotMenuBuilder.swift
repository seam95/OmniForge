import AppKit
import Foundation

/// 钉图托盘菜单纯构建：数据 → NSMenu，无 AppKit 控制器副作用。
/// 决策 8.4-13 / 8.5-9：锁定与穿透独立文案与动作。
@MainActor
enum PinnedScreenshotMenuBuilder {
    /// 菜单项 representedObject 载体（避免 UUID 直接塞 representedObject 的桥接歧义）。
    final class PinActionRef: NSObject {
        let id: UUID
        init(id: UUID) { self.id = id }
    }

    static func buildMenu(
        handles: [PinnedScreenshotHandle],
        strings: Strings,
        target: AnyObject,
        copySelector: Selector,
        saveSelector: Selector,
        toggleClickThroughSelector: Selector,
        toggleLockSelector: Selector,
        closeSelector: Selector,
        closeAllSelector: Selector
    ) -> NSMenu {
        let menu = NSMenu(title: strings.pinnedMenuTitle)

        if handles.isEmpty {
            let empty = NSMenuItem(title: strings.pinnedMenuEmpty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for (index, handle) in handles.enumerated() {
            let title = "\(index + 1). \(handle.displayLabel)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            let ref = PinActionRef(id: handle.id)

            let copy = NSMenuItem(
                title: strings.pinnedMenuCopy,
                action: copySelector,
                keyEquivalent: ""
            )
            copy.target = target
            copy.representedObject = ref
            submenu.addItem(copy)

            let save = NSMenuItem(
                title: strings.pinnedMenuSave,
                action: saveSelector,
                keyEquivalent: ""
            )
            save.target = target
            save.representedObject = ref
            submenu.addItem(save)

            submenu.addItem(.separator())

            // 穿透与锁定独立（决策 8.5-9）
            let clickThroughTitle = handle.isClickThrough
                ? strings.pinnedMenuDisableClickThrough
                : strings.pinnedMenuEnableClickThrough
            let clickThrough = NSMenuItem(
                title: clickThroughTitle,
                action: toggleClickThroughSelector,
                keyEquivalent: ""
            )
            clickThrough.target = target
            clickThrough.representedObject = ref
            clickThrough.state = handle.isClickThrough ? .on : .off
            submenu.addItem(clickThrough)

            let lockTitle = handle.isLocked ? strings.pinnedMenuUnlock : strings.pinnedMenuLock
            let lock = NSMenuItem(
                title: lockTitle,
                action: toggleLockSelector,
                keyEquivalent: ""
            )
            lock.target = target
            lock.representedObject = ref
            lock.state = handle.isLocked ? .on : .off
            submenu.addItem(lock)

            submenu.addItem(.separator())

            let close = NSMenuItem(
                title: strings.pinnedMenuClose,
                action: closeSelector,
                keyEquivalent: ""
            )
            close.target = target
            close.representedObject = ref
            submenu.addItem(close)

            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let closeAll = NSMenuItem(
            title: strings.pinnedMenuCloseAll,
            action: closeAllSelector,
            keyEquivalent: ""
        )
        closeAll.target = target
        menu.addItem(closeAll)
        return menu
    }
}
