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

/// IPC 消息载荷（用于在 DistributedNotificationCenter 中传递）
public struct RightClickIPCMessage: Codable {
    public var actionType: String
    public var parameter: String?
    public var targetURLs: [String]

    public init(actionType: String, parameter: String? = nil, targetURLs: [String] = []) {
        self.actionType = actionType
        self.parameter = parameter
        self.targetURLs = targetURLs
    }

    public static let notificationName = "app.omniforge.rightclick.action"
    public static let payloadUserInfoKey = "payload"
}
