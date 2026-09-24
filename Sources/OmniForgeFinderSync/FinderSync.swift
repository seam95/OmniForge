import Cocoa
import FinderSync
import OSLog

private let logger = Logger(subsystem: "app.omniforge.FinderSync", category: "menu")
private let clickLogger = Logger(subsystem: "app.omniforge.FinderSync", category: "click")

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
        logger.info("init: directoryURLs=\(controller.directoryURLs.map { $0.path }, privacy: .public)")

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

    // MARK: - 菜单动作入口

    /// 菜单动作快照。`menu(for:)` 每次构建时重建，点击时按 `sender.tag` 取回动作。
    private var menuActionSnapshot = MenuActionSnapshot()

    /// 菜单项点击入口。访达会忽略 item.target，直接把动作派发给扩展主体对象（本类），
    /// 因此处理函数必须定义在 FIFinderSync 子类上；载荷用 tag 索引快照而非 representedObject
    /// （后者无法跨 appex→访达的 XPC 桥存活）。
    @objc func handleMenuItemClick(_ sender: NSMenuItem) {
        guard let action = menuActionSnapshot.action(forTag: sender.tag) else {
            clickLogger.error("clicked tag=\(sender.tag) but snapshot has \(self.menuActionSnapshot.actions.count) entries")
            return
        }

        // Apple 文档明确许可在菜单动作内查询当前选区，且比构建时快照更准确
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        let urls = selected.isEmpty
            ? ([controller.targetedURL()].compactMap { $0 })
            : selected

        clickLogger.info("clicked \(action.type, privacy: .public) param=\(action.parameter ?? "-", privacy: .public) urls=\(urls.count)")
        FinderSyncIPC.shared.postAction(type: action.type, parameter: action.parameter, targetURLs: urls)
    }

    // MARK: - 菜单动态生成入口

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 读取总开关（若用户关闭了该特性，则不注入任何菜单项）。
        // 键名须与宿主 FeatureCatalog.availabilityKey（"featureAvailable.\(rawValue)"）一致；
        // 扩展处于沙盒内，只能读 app group，宿主已把 availability 镜像到该域。
        let defaults = UserDefaults(suiteName: FinderSyncAppGroup.identifier) ?? .standard
        let isEnabled = defaults.object(forKey: "featureAvailable.rightClickEnhancement") as? Bool ?? true
        logger.info("menu(for:) kind=\(menuKind.rawValue, privacy: .public) enabled=\(isEnabled)")
        guard isEnabled else {
            return nil
        }

        menuActionSnapshot = MenuActionSnapshot()

        let controller = FIFinderSyncController.default()

        switch menuKind {
        case .contextualMenuForContainer:
            // 用户在 Finder 窗口空白处或桌面空白处右键
            guard let targetedURL = controller.targetedURL() else {
                logger.error("container menu: targetedURL() returned nil")
                return nil
            }
            let builder = FinderSyncMenuBuilder(targetURLs: [targetedURL], isContainer: true, snapshot: menuActionSnapshot)
            let menu = builder.buildMenu()
            logger.info("container menu built: \(menu.numberOfItems) top-level items for \(targetedURL.path, privacy: .public)")
            return menu

        case .contextualMenuForItems:
            // 用户在具体文件或文件夹上右键
            guard let selectedURLs = controller.selectedItemURLs(), !selectedURLs.isEmpty else {
                logger.error("items menu: selectedItemURLs() empty/nil")
                return nil
            }
            let builder = FinderSyncMenuBuilder(targetURLs: selectedURLs, isContainer: false, snapshot: menuActionSnapshot)
            let menu = builder.buildMenu()
            logger.info("items menu built: \(menu.numberOfItems) top-level items for \(selectedURLs.count) urls")
            return menu

        default:
            return nil
        }
    }
}
