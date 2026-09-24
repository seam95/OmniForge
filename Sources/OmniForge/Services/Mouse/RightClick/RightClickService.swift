import AppKit
import Foundation

/// 访达右键增强宿主服务
@MainActor
public final class RightClickService: ObservableObject {
    public static let shared = RightClickService()

    @Published public private(set) var isRunning = false

    private let executor: RightClickActionExecutor
    private let configuration: RightClickConfiguration
    private var observerToken: NSObjectProtocol?

    public init(
        executor: RightClickActionExecutor = RightClickActionExecutor(),
        configuration: RightClickConfiguration = .shared
    ) {
        self.executor = executor
        self.configuration = configuration
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
        let center = DistributedNotificationCenter.default()
        let name = NSNotification.Name(RightClickIPCMessage.notificationName)

        observerToken = center.addObserver(
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
            DistributedNotificationCenter.default().removeObserver(token)
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

        do {
            switch message.actionType {
            case "newFile":
                let ext = message.parameter ?? "txt"
                if let targetDir = targetURLs.first {
                    try executor.createUniqueEmptyFile(in: targetDir, fileExtension: ext)
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

            case "moveTo":
                guard let destPath = message.parameter else { return }
                let destURL = URL(fileURLWithPath: destPath)
                try executor.moveFiles(targetURLs, to: destURL)

            case "copyTo":
                guard let destPath = message.parameter else { return }
                let destURL = URL(fileURLWithPath: destPath)
                try executor.copyFiles(targetURLs, to: destURL)

            case "quickJump":
                guard let jumpPath = message.parameter else { return }
                let jumpURL = URL(fileURLWithPath: jumpPath)
                NSWorkspace.shared.open(jumpURL)

            case "toggleHiddenFiles":
                // 切换后访达会被重启以重新枚举窗口，返回值即切换后的可见性
                let nowVisible = executor.toggleHiddenFiles()
                NSLog("[OmniForge RightClick] 隐藏文件可见性切换为 %@", nowVisible ? "显示" : "隐藏")

            default:
                break
            }
        } catch {
            NSLog("[OmniForge RightClick] 执行操作 [%@] 失败: %@", message.actionType, error.localizedDescription)
        }
    }
}
