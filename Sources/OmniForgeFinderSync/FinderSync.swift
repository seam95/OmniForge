import Cocoa
import FinderSync

class FinderSync: FIFinderSync {

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()

        // 监控所有已挂载磁盘卷
        if let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) {
            controller.directoryURLs = Set<URL>(mountedVolumes)
        }

        // 动态追踪外接磁盘的插入与挂载
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                controller.directoryURLs.insert(volumeURL)
            }
        }
    }

    // MARK: - 菜单动态生成入口

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 读取总开关（若用户关闭了该特性，则不注入任何菜单项）
        let defaults = UserDefaults(suiteName: "group.app.omniforge") ?? .standard
        let isEnabled = defaults.object(forKey: "featureAvailable_rightClickEnhancement") as? Bool ?? true
        guard isEnabled else {
            return nil
        }

        let controller = FIFinderSyncController.default()

        switch menuKind {
        case .contextualMenuForContainer:
            // 用户在 Finder 窗口空白处或桌面空白处右键
            guard let targetedURL = controller.targetedURL() else {
                return nil
            }
            let builder = FinderSyncMenuBuilder(targetURLs: [targetedURL], isContainer: true)
            return builder.buildMenu()

        case .contextualMenuForItems:
            // 用户在具体文件或文件夹上右键
            guard let selectedURLs = controller.selectedItemURLs(), !selectedURLs.isEmpty else {
                return nil
            }
            let builder = FinderSyncMenuBuilder(targetURLs: selectedURLs, isContainer: false)
            return builder.buildMenu()

        default:
            return nil
        }
    }
}
