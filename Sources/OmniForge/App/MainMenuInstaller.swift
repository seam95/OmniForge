import AppKit

/// 主菜单安装器 — 为 accessory（LSUIElement）应用安装标准菜单。
/// accessory 应用没有默认主菜单，导致 Cmd+H/M/W/Q 和 Edit 快捷键失效。
/// 安装后 Settings 窗口中的文本框才能响应 Cmd+C/V/X/A 等快捷键。
enum MainMenuInstaller {

    /// 构建完整的 NSMenu 结构。target 接收设置菜单项的 action。
    /// 传 nil 时设置项的 target 为 nil（菜单项不会触发）。
    static func makeMenu(target: AnyObject?, strings: Strings) -> NSMenu {
        let mainMenu = NSMenu()

        // MARK: 应用菜单（加粗的、以应用名命名的第一个菜单）

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: strings.menuAbout,
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: strings.menuSettings,
            action: #selector(MainMenuSettingsTarget.openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = target
        appMenu.addItem(settingsItem)

        let shelfItem = NSMenuItem(
            title: strings.shelfMenuItem,
            action: #selector(MainMenuSettingsTarget.openShelf),
            keyEquivalent: ""
        )
        shelfItem.target = target
        appMenu.addItem(shelfItem)

        // 截图子菜单：与快捷键共用同一 handler，keyEquivalent 留空避免双触发。
        let screenshotRoot = NSMenuItem(
            title: strings.screenshotMenuTitle,
            action: nil,
            keyEquivalent: ""
        )
        let screenshotMenu = NSMenu(title: strings.screenshotMenuTitle)
        let screenshotEntries: [(String, Selector)] = [
            (strings.screenshotHotkeyAllInOne, #selector(MainMenuSettingsTarget.captureScreenshotAllInOne)),
            (strings.screenshotHotkeyFullscreen, #selector(MainMenuSettingsTarget.captureScreenshotFullscreen)),
        ]
        for (title, selector) in screenshotEntries {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = target
            screenshotMenu.addItem(item)
        }
        screenshotRoot.submenu = screenshotMenu
        appMenu.addItem(screenshotRoot)

        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: strings.menuHide,
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: strings.menuHideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: strings.menuShowAll,
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: strings.menuQuit,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // MARK: 编辑菜单（Settings 窗口中的文本框需要这些快捷键）

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: strings.menuEdit)
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(
            title: strings.menuUndo,
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redo = NSMenuItem(
            title: strings.menuRedo,
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: strings.menuCut,
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: strings.menuCopy,
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: strings.menuPaste,
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: strings.menuSelectAll,
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))

        // MARK: 窗口菜单（最小化 / 缩放 / 关闭）

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: strings.menuWindow)
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(NSMenuItem(
            title: strings.menuMinimize,
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))
        windowMenu.addItem(NSMenuItem(
            title: strings.menuZoom,
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(
            title: strings.menuClose,
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))

        return mainMenu
    }

    /// 构建 NSMenu 并安装为 NSApp.mainMenu，同时设置 NSApp.windowsMenu。
    /// target 接收设置菜单项的 action。
    static func install(target: AnyObject?, strings: Strings) {
        let menu = makeMenu(target: target, strings: strings)
        NSApp.mainMenu = menu
        // windowsMenu 让 AppKit 自动管理窗口菜单项的启用状态
        if let windowMenuItem = menu.item(at: 2) {
            NSApp.windowsMenu = windowMenuItem.submenu
        }
    }
}

/// 设置菜单项的 action 目标协议。
/// AppDelegate 需实现 openSettings / openShelf / 截图入口方法。
@MainActor @objc protocol MainMenuSettingsTarget: AnyObject {
    @objc func openSettings()
    @objc func openShelf()
    @objc func captureScreenshotAllInOne()
    @objc func captureScreenshotFullscreen()
}
