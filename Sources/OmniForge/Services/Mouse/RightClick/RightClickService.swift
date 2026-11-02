import AppKit
import Foundation

/// 右键动作执行层的最小接口：服务只依赖它实际用到的动作集合，
/// 以协议抽象隔离具体执行器，便于测试注入 spy 而不触碰真实文件系统。
public protocol RightClickActionExecuting {
    func createUniqueEmptyFile(in directoryURL: URL, fileExtension: String, baseName: String) throws -> URL
    func openTerminal(at targetURL: URL, bundleId: String?) throws
    func open(urls: [URL], withAppBundleIdentifier bundleId: String) throws
    @discardableResult
    func copyPathsToPasteboard(_ urls: [URL], format: RightClickPathFormat) -> String
    func moveFiles(_ sourceURLs: [URL], to targetDirectoryURL: URL) throws -> [URL]
    func copyFiles(_ sourceURLs: [URL], to targetDirectoryURL: URL) throws -> [URL]
    @discardableResult
    func toggleHiddenFiles() -> Bool
}

extension RightClickActionExecutor: RightClickActionExecuting {}

/// 访达右键增强宿主服务
@MainActor
// 与 DesktopPetManager 一致保持 internal：stringsProvider 依赖 internal 的 Strings/L10n，
// 且本类型没有模块外使用者。
final class RightClickService: ObservableObject {
    // 不要提供 static shared：本服务由 FeatureFactory 创建并注册到 FeatureRuntime，
    // 启停统一走注册表实例。曾因 binding 另启一个单例，导致同一通知被处理两次。
    @Published private(set) var isRunning = false

    /// App Group 域中共享 IPC 令牌的键。扩展端 FinderSyncIPC 声明了同名常量——
    /// 两端无法共享代码（appex 目标 dependencies 为空），改动时必须同步。
    static let ipcTokenKey = "rightclick.ipcToken"

    private let executor: any RightClickActionExecuting
    private let configuration: RightClickConfiguration
    private let stringsProvider: () -> Strings
    private let notificationCenter: NotificationCenter
    /// 令牌的读写域：必须是 App Group 的 UserDefaults——写 .standard 沙盒扩展读不到，
    /// 校验会永远失败。
    private let tokenDefaults: UserDefaults?
    /// 缺辅助功能权限时的引导回调；抽成依赖以便测试注入 spy，避免单测弹真实系统授权框。
    private let accessibilityPrompter: () -> Void
    private var observerToken: NSObjectProtocol?
    /// 当前期望的 IPC 令牌；start() 时从 App Group 读取或生成。
    private var expectedToken: String?

    init(
        executor: any RightClickActionExecuting = RightClickActionExecutor(),
        configuration: RightClickConfiguration = .shared,
        notificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        tokenDefaults: UserDefaults? = UserDefaults(suiteName: RightClickConfiguration.appGroupIdentifier),
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s },
        // 默认参数求值处于非隔离上下文，不能同步调用 MainActor 的权限请求；
        // 派发回主线程执行（授权弹窗本就允许稍后一拍出现）。
        accessibilityPrompter: @escaping () -> Void = {
            Task { @MainActor in
                Permissions.shared.requestAccess(for: .accessibility)
            }
        }
    ) {
        self.executor = executor
        self.configuration = configuration
        self.notificationCenter = notificationCenter
        self.tokenDefaults = tokenDefaults
        self.stringsProvider = stringsProvider
        self.accessibilityPrompter = accessibilityPrompter
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        loadOrCreateSharedToken()
        registerNotificationObserver()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterNotificationObserver()
    }

    /// 读取或生成 App Group 共享令牌。
    /// - 已有令牌：直接沿用，不在重启时轮换——轮换会让扩展手中的旧令牌在窗口期失效。
    /// - 首次启动：生成随机 UUID 写入 App Group 域（不写 .standard：沙盒扩展读不到）。
    /// - 拿不到 App Group 域：expectedToken 保持 nil，后续校验一律拒绝（fail-closed）。
    private func loadOrCreateSharedToken() {
        if let existing = tokenDefaults?.string(forKey: Self.ipcTokenKey) {
            expectedToken = existing
            return
        }
        guard let tokenDefaults else { return }
        let token = UUID().uuidString
        tokenDefaults.set(token, forKey: Self.ipcTokenKey)
        expectedToken = token
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

        // 威胁模型：分布式通知是系统全局总线，任何本地进程都能以任意 object 发出同名
        // 通知，借宿主已获的 TCC 授权（文件访问、辅助功能）执行 moveTo/copyTo 等文件
        // 操作。载荷必须携带 App Group 共享令牌；缺失（旧版扩展或伪造者省略字段）或
        // 不匹配一律拒绝执行——放行 nil 会立即构成降级攻击面。
        guard let expectedToken, message.token == expectedToken else { return }

        // URL(string:) 在新 Foundation 下会对空格等非法字符自动百分号编码并解析成
        // 相对 URL，compactMap { URL(string:) } 过滤不掉这类垃圾输入；文件操作的
        // 目标必须是 file:// 绝对 URL，其余（相对路径、其他 scheme）一律丢弃。
        let targetURLs = message.targetURLs.compactMap { urlString -> URL? in
            guard let url = URL(string: urlString), url.scheme == "file" else { return nil }
            return url
        }

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
                        accessibilityPrompter()
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
