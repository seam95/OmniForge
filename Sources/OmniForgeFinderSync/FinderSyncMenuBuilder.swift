import Cocoa

final class FinderSyncMenuActionTarget: NSObject {
    static let shared = FinderSyncMenuActionTarget()

    @objc func onMenuItemClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let actionType = info["actionType"] as? String else {
            return
        }
        let param = info["parameter"] as? String
        let urls = info["targetURLs"] as? [URL] ?? []

        FinderSyncIPC.shared.postAction(type: actionType, parameter: param, targetURLs: urls)
    }
}

final class FinderSyncMenuBuilder {
    private let targetURLs: [URL]
    private let isContainer: Bool
    private let defaults: UserDefaults

    init(targetURLs: [URL], isContainer: Bool) {
        self.targetURLs = targetURLs
        self.isContainer = isContainer
        self.defaults = UserDefaults(suiteName: "group.app.omniforge") ?? .standard
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
            if let icon = NSImage(named: NSImage.Name("NSActionTemplate")) {
                mainFolderItem.image = icon
            }
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

    // MARK: - 构建具体子菜单

    private func makeNewFileMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "新建文件")

        let extensions = defaults.stringArray(forKey: "rightClick_fileExtensions") ?? ["txt", "md", "json", "sh", "swift", "py"]
        for ext in extensions {
            let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let item = NSMenuItem(title: "\(clean.uppercased()) 文件 (.\(clean))", action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
            item.target = FinderSyncMenuActionTarget.shared
            item.representedObject = [
                "actionType": "newFile",
                "parameter": clean,
                "targetURLs": targetURLs
            ]
            sub.addItem(item)
        }
        parentItem.submenu = sub
        return parentItem
    }

    private func makeOpenTerminalMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "在此处打开终端", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "在此处打开终端")

        let terminals = [
            ("系统终端", "com.apple.Terminal"),
            ("iTerm2", "com.googlecode.iterm2"),
            ("Warp", "dev.warp"),
            ("Ghostty", "com.mitchellh.ghostty")
        ]

        for (name, bundleId) in terminals {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
                let item = NSMenuItem(title: name, action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
                item.target = FinderSyncMenuActionTarget.shared
                item.representedObject = [
                    "actionType": "openTerminal",
                    "parameter": bundleId,
                    "targetURLs": targetURLs
                ]
                sub.addItem(item)
            }
        }

        if sub.items.isEmpty {
            let defaultItem = NSMenuItem(title: "终端 (Terminal)", action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
            defaultItem.target = FinderSyncMenuActionTarget.shared
            defaultItem.representedObject = [
                "actionType": "openTerminal",
                "parameter": "com.apple.Terminal",
                "targetURLs": targetURLs
            ]
            sub.addItem(defaultItem)
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeOpenEditorMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "在此处打开编辑器", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "在此处打开编辑器")

        let editors = [
            ("VS Code", "com.microsoft.VSCode"),
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Zed", "dev.zed.Zed"),
            ("Sublime Text", "com.sublimetext.4")
        ]

        for (name, bundleId) in editors {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil {
                let item = NSMenuItem(title: name, action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
                item.target = FinderSyncMenuActionTarget.shared
                item.representedObject = [
                    "actionType": "openEditor",
                    "parameter": bundleId,
                    "targetURLs": targetURLs
                ]
                sub.addItem(item)
            }
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeCopyPathMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "复制路径", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "复制路径")

        let formats: [(String, String)] = [
            ("绝对路径 (POSIX)", "posix"),
            ("Shell 转义路径", "shellEscaped"),
            ("文件 URL", "url"),
            ("仅文件名", "fileName")
        ]

        for (title, format) in formats {
            let item = NSMenuItem(title: title, action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
            item.target = FinderSyncMenuActionTarget.shared
            item.representedObject = [
                "actionType": "copyPath",
                "parameter": format,
                "targetURLs": targetURLs
            ]
            sub.addItem(item)
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeMoveToMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "移动到...", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "移动到...")

        let directories = getDirectories()
        for dir in directories {
            let item = NSMenuItem(title: dir.0, action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
            item.target = FinderSyncMenuActionTarget.shared
            item.representedObject = [
                "actionType": "moveTo",
                "parameter": dir.1,
                "targetURLs": targetURLs
            ]
            sub.addItem(item)
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeCopyToMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "复制到...", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "复制到...")

        let directories = getDirectories()
        for dir in directories {
            let item = NSMenuItem(title: dir.0, action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
            item.target = FinderSyncMenuActionTarget.shared
            item.representedObject = [
                "actionType": "copyTo",
                "parameter": dir.1,
                "targetURLs": targetURLs
            ]
            sub.addItem(item)
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeQuickJumpMenuItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "常用目录直达", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "常用目录直达")

        let directories = getDirectories()
        for dir in directories {
            let item = NSMenuItem(title: dir.0, action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
            item.target = FinderSyncMenuActionTarget.shared
            item.representedObject = [
                "actionType": "quickJump",
                "parameter": dir.1,
                "targetURLs": targetURLs
            ]
            sub.addItem(item)
        }

        parentItem.submenu = sub
        return parentItem
    }

    private func makeToggleHiddenFilesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "切换显示隐藏文件", action: #selector(FinderSyncMenuActionTarget.onMenuItemClicked(_:)), keyEquivalent: "")
        item.target = FinderSyncMenuActionTarget.shared
        item.representedObject = [
            "actionType": "toggleHiddenFiles",
            "targetURLs": targetURLs
        ]
        return item
    }

    private func getDirectories() -> [(String, String)] {
        let fm = FileManager.default
        var list: [(String, String)] = []
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            list.append(("桌面", desktop.path))
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            list.append(("下载", downloads.path))
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            list.append(("文稿", docs.path))
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
