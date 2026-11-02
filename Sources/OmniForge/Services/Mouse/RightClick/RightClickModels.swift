import Foundation

/// 路径复制格式
public enum RightClickPathFormat: String, Codable, CaseIterable {
    case posix
    case shellEscaped
    case url
    case fileName
}

/// 右键增强操作类型
public enum RightClickAction: Equatable {
    case newFile(extension: String)
    case openTerminal(bundleId: String?)
    case openEditor(bundleId: String?)
    case copyPath(format: RightClickPathFormat)
    case moveTo(targetPath: String)
    case copyTo(targetPath: String)
    case quickJump(targetPath: String)
    case toggleHiddenFiles
}

/// 常用目录条目
public struct RightClickDirectoryItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var isCustom: Bool

    public init(id: UUID = UUID(), name: String, path: String, isCustom: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.isCustom = isCustom
    }
}

/// IPC 消息载荷（用于在 DistributedNotificationCenter 中传递）。
/// 载荷经通知的 `object` 传递而非 `userInfo`：沙盒化的 FinderSync 扩展发送带
/// `userInfo` 的分布式通知会被系统拦截丢弃。
public struct RightClickIPCMessage: Codable {
    public var actionType: String
    public var parameter: String?
    public var targetURLs: [String]
    /// 共享令牌：宿主借此校验发送方身份。分布式通知是系统全局总线，任何本地
    /// 进程都能发同名通知；令牌由宿主启动时写入 App Group，只有真正的扩展读得到。
    /// 设为可选仅为兼容旧版扩展的一次发布窗口（解码不失败），宿主对 nil 一律拒绝执行。
    public var token: String?

    public init(actionType: String, parameter: String? = nil, targetURLs: [String] = [], token: String? = nil) {
        self.actionType = actionType
        self.parameter = parameter
        self.targetURLs = targetURLs
        self.token = token
    }

    public static let notificationName = "app.omniforge.rightclick.action"
}
