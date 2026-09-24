import Cocoa

/// 菜单动作载荷。经 NSMenuItem.tag 在扩展进程内传递。
struct MenuAction {
    let type: String
    let parameter: String?
}

/// 动作快照：`menu(for:)` 构建菜单时按插入顺序记录，点击时用 `sender.tag` 取回。
/// representedObject 无法跨 appex→访达的 XPC 桥存活（ownCloud、newfile 源码注释均有记载），
/// 因此 tag 是唯一可靠的载体。
final class MenuActionSnapshot {
    private(set) var actions: [MenuAction] = []

    @discardableResult
    func append(_ action: MenuAction) -> Int {
        actions.append(action)
        return actions.count - 1
    }

    func action(forTag tag: Int) -> MenuAction? {
        guard tag >= 0, tag < actions.count else { return nil }
        return actions[tag]
    }
}

final class FinderSyncMenuBuilder {
    private let targetURLs: [URL]
    private let isContainer: Bool
    private let defaults: UserDefaults
    private let snapshot: MenuActionSnapshot

    init(targetURLs: [URL], isContainer: Bool, snapshot: MenuActionSnapshot) {
        self.targetURLs = targetURLs
        self.isContainer = isContainer
        self.defaults = UserDefaults(suiteName: FinderSyncAppGroup.identifier) ?? .standard
        self.snapshot = snapshot
    }

    func buildMenu() -> NSMenu {
        let rootMenu = NSMenu(title: "")
        let subMenu = NSMenu(title: "OmniForge")

        let isCollapsed = defaults.object(forKey: "rightClick_isSubmenuCollapsed") as? Bool ?? true
        let promotedKeys = Set(defaults.stringArray(forKey: "rightClick_promotedActionKeys") ?? [])

        // 1. 新建文件
        let newFileItem = makeNewFileMenuItem()
        attachMenuItem(newFileItem, actionKey: "newFile", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

        // 2. 在终端中打开
        let openTerminalItem = makeOpenTerminalMenuItem()
        attachMenuItem(openTerminalItem, actionKey: "openTerminal", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

        // 3. 在编辑器中打开
        let openEditorItem = makeOpenEditorMenuItem()
        attachMenuItem(openEditorItem, actionKey: "openEditor", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

        // 4. 复制路径
        let copyPathItem = makeCopyPathMenuItem()
        attachMenuItem(copyPathItem, actionKey: "copyPath", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

        // 5. 快捷文件操作（移动到/复制到/直达）
        if !isContainer && !targetURLs.isEmpty {
            let moveItem = makeMoveToMenuItem()
            attachMenuItem(moveItem, actionKey: "moveTo", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

            let copyItem = makeCopyToMenuItem()
            attachMenuItem(copyItem, actionKey: "copyTo", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)
        }

        let jumpItem = makeQuickJumpMenuItem()
        attachMenuItem(jumpItem, actionKey: "quickJump", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

        // 6. 切换显示隐藏文件
        let hiddenItem = makeToggleHiddenFilesMenuItem()
        attachMenuItem(hiddenItem, actionKey: "toggleHiddenFiles", promotedKeys: promotedKeys, isCollapsed: isCollapsed, rootMenu: rootMenu, subMenu: subMenu)

        // 如果开启了二级收敛，且 subMenu 中有未被提升的菜单项，则把 subMenu 作为一级项挂到 rootMenu
        if isCollapsed && !subMenu.items.isEmpty {
            let mainFolderItem = NSMenuItem(title: "OmniForge", action: nil, keyEquivalent: "")
            mainFolderItem.image = Self.brandMenuIcon()
            mainFolderItem.submenu = subMenu
            rootMenu.addItem(mainFolderItem)
        }

        return rootMenu
    }

    private func attachMenuItem(
        _ item: NSMenuItem,
        actionKey: String,
        promotedKeys: Set<String>,
        isCollapsed: Bool,
        rootMenu: NSMenu,
        subMenu: NSMenu
    ) {
        if !isCollapsed || promotedKeys.contains(actionKey) {
            rootMenu.addItem(item)
        } else {
            subMenu.addItem(item)
        }
    }

    /// 构造一个可点击的动作菜单项。
    /// action 由扩展主体（FIFinderSync 子类）提供——访达会忽略 item.target，
    /// 直接把动作派发给扩展主体对象；载荷用 tag 索引快照，不用 representedObject。
    private func makeActionItem(title: String, actionType: String, parameter: String?) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(FinderSync.handleMenuItemClick(_:)),
            keyEquivalent: ""
        )
        item.tag = snapshot.append(MenuAction(type: actionType, parameter: parameter))
        return item
    }

    /// OmniForge App 图标（菜单用）。
    /// 宿主与扩展不共享 bundle，appex 需自带该资源——由 build.sh 从
    /// Resources/Assets.xcassets/AppIcon.appiconset 拷贝为 appicon_menu.png。
    /// 源图 64px，显式缩到 14×14pt：菜单行高约 20pt，超过 16pt 就会顶满整行糊成一团。
    /// 彩色图标不做 isTemplate——模板渲染会把它压成纯黑剪影。
    /// 资源缺失时退回该功能在应用内使用的 SF Symbol。
    static func brandMenuIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "appicon_menu", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 14, height: 14)
            return image
        }
        if let fallback = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil) {
            fallback.isTemplate = true
            return fallback
        }
        return nil
    }

    // MARK: - 构建具体子菜单

    private func makeNewFileMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.newFile, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.newFile)

        let extensions = defaults.stringArray(forKey: "rightClick_fileExtensions") ?? ["txt", "md", "json", "sh", "swift", "py"]
        for ext in extensions {
            let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            sub.addItem(makeActionItem(title: FinderSyncStrings.newFileItem(clean.uppercased()), actionType: "newFile", parameter: clean))
        }
        parentItem.submenu = sub
        return parentItem
    }

    private func makeOpenTerminalMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.openTerminal, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.openTerminal)

        let terminals = [
            ("系统终端", "com.apple.Terminal"),
            ("iTerm2", "com.googlecode.iterm2"),
            ("Warp", "dev.warp"),
            ("Ghostty", "com.mitchellh.ghostty")
        ]

        for (name, bundleId) in terminals {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
                sub.addItem(makeActionItem(title: name, actionType: "openTerminal", parameter: bundleId))
            }
        }

        if sub.items.isEmpty {
            sub.addItem(makeActionItem(title: FinderSyncStrings.terminalFallback, actionType: "openTerminal", parameter: "com.apple.Terminal"))
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeOpenEditorMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.openEditor, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.openEditor)

        let editors = [
            ("VS Code", "com.microsoft.VSCode"),
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Zed", "dev.zed.Zed"),
            ("Sublime Text", "com.sublimetext.4")
        ]

        for (name, bundleId) in editors {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
                sub.addItem(makeActionItem(title: name, actionType: "openEditor", parameter: bundleId))
            }
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeCopyPathMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.copyPath, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.copyPath)

        let formats: [(String, String)] = [
            (FinderSyncStrings.pathPOSIX, "posix"),
            (FinderSyncStrings.pathShellEscaped, "shellEscaped"),
            (FinderSyncStrings.pathURL, "url"),
            (FinderSyncStrings.pathFileName, "fileName")
        ]

        for (title, format) in formats {
            sub.addItem(makeActionItem(title: title, actionType: "copyPath", parameter: format))
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeMoveToMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.moveTo, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.moveTo)

        let directories = getDirectories()
        for dir in directories {
            sub.addItem(makeActionItem(title: dir.0, actionType: "moveTo", parameter: dir.1))
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeCopyToMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.copyTo, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.copyTo)

        let directories = getDirectories()
        for dir in directories {
            sub.addItem(makeActionItem(title: dir.0, actionType: "copyTo", parameter: dir.1))
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeQuickJumpMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: FinderSyncStrings.quickJump, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: FinderSyncStrings.quickJump)

        let directories = getDirectories()
        for dir in directories {
            sub.addItem(makeActionItem(title: dir.0, actionType: "quickJump", parameter: dir.1))
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeToggleHiddenFilesMenuItem() -> NSMenuItem {
        return makeActionItem(title: FinderSyncStrings.toggleHiddenFiles, actionType: "toggleHiddenFiles", parameter: nil)
    }

    private func getDirectories() -> [(String, String)] {
        let fm = FileManager.default
        var list: [(String, String)] = []
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            list.append((FinderSyncStrings.dirDesktop, desktop.path))
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            list.append((FinderSyncStrings.dirDownloads, downloads.path))
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            list.append((FinderSyncStrings.dirDocuments, docs.path))
        }

        // 自定义目录数据反序列化
        if let data = defaults.data(forKey: "rightClick_favoriteDirectories"),
           let items = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
            for dict in items {
                if let name = dict["name"] as? String, let path = dict["path"] as? String {
                    if !list.contains(where: { $0.1 == path }) {
                        list.append((name, path))
                    }
                }
            }
        }
        return list
    }
}
