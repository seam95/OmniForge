import AppKit
import Foundation

/// 访达右键增强宿主服务
@MainActor
// 与 DesktopPetManager 一致保持 internal：stringsProvider 依赖 internal 的 Strings/L10n，
// 且本类型没有模块外使用者。
final class RightClickService: ObservableObject {
    // 不要提供 static shared：本服务由 FeatureFactory 创建并注册到 FeatureRuntime，
    // 启停统一走注册表实例。曾因 binding 另启一个单例，导致同一通知被处理两次。
    @Published private(set) var isRunning = false

    private let executor: RightClickActionExecutor
    private let configuration: RightClickConfiguration
    private let stringsProvider: () -> Strings
    private let notificationCenter: NotificationCenter
    private var observerToken: NSObjectProtocol?

    init(
        executor: RightClickActionExecutor = RightClickActionExecutor(),
        configuration: RightClickConfiguration = .shared,
        notificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s }
    ) {
        self.executor = executor
        self.configuration = configuration
        self.notificationCenter = notificationCenter
        self.stringsProvider = stringsProvider
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        registerNotificationObserver()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterNotificationObserver()
    }

    // MARK: - IPC 接收与分发

    private func registerNotificationObserver() {
        unregisterNotificationObserver()
        let name = NSNotification.Name(RightClickIPCMessage.notificationName)

        observerToken = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleNotification(notification)
            }
        }
    }

    private func unregisterNotificationObserver() {
        if let token = observerToken {
            notificationCenter.removeObserver(token)
            observerToken = nil
        }
    }

    private func handleNotification(_ notification: Notification) {
        // 载荷取自 notification.object：沙盒化的 FinderSync 扩展发不出带 userInfo 的分布式
        // 通知（会被沙盒拦截丢弃），只能走 object。参见 FinderSyncIPC.postAction。
        guard let jsonString = notification.object as? String,
              let jsonData = jsonString.data(using: .utf8),
              let message = try? JSONDecoder().decode(RightClickIPCMessage.self, from: jsonData) else {
            return
        }

        let targetURLs = message.targetURLs.compactMap { URL(string: $0) }

        // moveTo / copyTo 可能拷大量数据，放在主线程会把界面卡住；其余动作都很快，
        // 留在主线程（NSPasteboard 与 NSWorkspace 的调用需要在主线程）。
        switch message.actionType {
        case "moveTo", "copyTo":
            let destPath = message.parameter ?? ""
            Task.detached(priority: .userInitiated) { [executor] in
                let destURL = URL(fileURLWithPath: destPath)
                do {
                    if message.actionType == "moveTo" {
                        try executor.moveFiles(targetURLs, to: destURL)
                    } else {
                        try executor.copyFiles(targetURLs, to: destURL)
                    }
                } catch {
                    await MainActor.run {
                        NSLog("[OmniForge RightClick] 执行操作 [%@] 失败: %@", message.actionType, error.localizedDescription)
                    }
                }
            }

        default:
            do {
                switch message.actionType {
                case "newFile":
                    let ext = message.parameter ?? "txt"
                    if let targetDir = targetURLs.first {
                        try executor.createUniqueEmptyFile(
                            in: targetDir,
                            fileExtension: ext,
                            baseName: stringsProvider().rightClickNewFileBaseName
                        )
                    }

                case "openTerminal":
                    let bundleId = message.parameter
                    if let target = targetURLs.first {
                        try executor.openTerminal(at: target, bundleId: bundleId)
                    }

                case "openEditor":
                    guard let bundleId = message.parameter else { return }
                    try executor.open(urls: targetURLs, withAppBundleIdentifier: bundleId)

                case "copyPath":
                    let rawFormat = message.parameter ?? "posix"
                    let format = RightClickPathFormat(rawValue: rawFormat) ?? .posix
                    executor.copyPathsToPasteboard(targetURLs, format: format)

                case "quickJump":
                    guard let jumpPath = message.parameter else { return }
                    let jumpURL = URL(fileURLWithPath: jumpPath)
                    NSWorkspace.shared.open(jumpURL)

                case "toggleHiddenFiles":
                    // 走访达快捷键即时切换，不重启进程；失败说明缺少辅助功能权限。
                    if executor.toggleHiddenFiles() {
                        NSLog("[OmniForge RightClick] 已发送隐藏文件切换快捷键")
                    } else {
                        NSLog("[OmniForge RightClick] 缺少辅助功能权限，无法切换隐藏文件")
                        Permissions.shared.requestAccess(for: .accessibility)
                    }

                default:
                    break
                }
            } catch {
                NSLog("[OmniForge RightClick] 执行操作 [%@] 失败: %@", message.actionType, error.localizedDescription)
            }
        }
    }
}
