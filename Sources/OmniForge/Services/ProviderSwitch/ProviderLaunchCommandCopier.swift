import AppKit
import Foundation

/// 启动命令复制边界，便于 UI 与系统剪贴板解耦测试。
protocol ProviderLaunchCommandCopying: AnyObject {
    @discardableResult
    func copyLaunchCommand(for profile: ProviderProfile) -> Bool
}

/// 将供应商档案对应的启动命令写入系统剪贴板。
final class ProviderLaunchCommandCopier: ProviderLaunchCommandCopying {
    private let writer: PasteboardWriting
    private let homePath: String
    private let environment: [String: String]

    init(
        writer: PasteboardWriting = SystemPasteboardWriter(),
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.writer = writer
        self.homePath = homePath
        self.environment = environment
    }

    @discardableResult
    func copyLaunchCommand(for profile: ProviderProfile) -> Bool {
        let command = ProviderLaunchCommand.make(
            for: profile,
            homePath: homePath,
            environment: environment
        )
        writer.clearContents()
        return writer.setString(command, forType: .string)
    }
}
