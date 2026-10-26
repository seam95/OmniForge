import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum RightClickError: LocalizedError, Equatable {
    case fileCreationFailed(String)
    case destinationNotFound(String)
    case moveFailed(String)
    case copyFailed(String)
    case appLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileCreationFailed(let path):
            return "创建文件失败: \(path)"
        case .destinationNotFound(let path):
            return "目标目录不存在: \(path)"
        case .moveFailed(let reason):
            return "移动文件失败: \(reason)"
        case .copyFailed(let reason):
            return "复制文件失败: \(reason)"
        case .appLaunchFailed(let app):
            return "调起应用失败: \(app)"
        }
    }
}

/// 访达「显示/隐藏隐藏文件」切换器。以协议隔离系统事件投递，便于测试替身。
public protocol FinderHiddenFilesToggling {
    /// 返回是否成功投递快捷键；未获辅助功能权限时为 false。
    @discardableResult
    func toggleHiddenFiles() -> Bool
}

/// 向当前前台访达窗口发送 ⌘⇧.。
/// 系统没有能在运行中修改 `AppleShowAllFiles` 偏好的公开接口：写入偏好后必须重启访达
/// 才重新读取，因此这里改用访达内置快捷键，即时切换且不重启进程。
public struct SystemFinderHiddenFilesToggler: FinderHiddenFilesToggling {
    public init() {}

    public func toggleHiddenFiles() -> Bool {
        // 向其他进程投递键盘事件需要辅助功能权限，未授权时事件会被静默丢弃
        guard AXIsProcessTrusted() else { return false }

        // kVK_ANSI_Period = 0x2F
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x2F, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x2F, keyDown: false) else {
            return false
        }
        keyDown.flags = [.maskCommand, .maskShift]
        keyUp.flags = [.maskCommand, .maskShift]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

/// 访达右键操作执行器
public final class RightClickActionExecutor {
    private let fileManager: FileManager
    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private let hiddenFilesToggler: FinderHiddenFilesToggling
    private let fileRevealer: ([URL]) -> Void

    public init(
        fileManager: FileManager = .default,
        pasteboard: NSPasteboard = .general,
        workspace: NSWorkspace = .shared,
        hiddenFilesToggler: FinderHiddenFilesToggling = SystemFinderHiddenFilesToggler(),
        fileRevealer: @escaping ([URL]) -> Void = { urls in
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    ) {
        self.fileManager = fileManager
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.hiddenFilesToggler = hiddenFilesToggler
        self.fileRevealer = fileRevealer
    }

    /// 确保解析出有效的目标目录（若为文件则取其所在目录）
    public func ensureDirectoryURL(_ url: URL) -> URL {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : url.deletingLastPathComponent()
        }
        return url.hasDirectoryPath ? url : url.deletingLastPathComponent()
    }

    // MARK: - 1. 新建空白文件

    /// 在指定目录下创建不重名的空白文件并高亮选中
    @discardableResult
    public func createUniqueEmptyFile(
        in directoryURL: URL,
        fileExtension: String,
        baseName: String = "未命名"
    ) throws -> URL {
        let cleanExt = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        
        let destinationDir = ensureDirectoryURL(directoryURL)
        
        var candidateURL: URL
        if cleanExt.isEmpty {
            candidateURL = destinationDir.appendingPathComponent(baseName)
        } else {
            candidateURL = destinationDir.appendingPathComponent("\(baseName).\(cleanExt)")
        }

        var counter = 2
        while fileManager.fileExists(atPath: candidateURL.path) {
            let nextName = "\(baseName) \(counter)"
            if cleanExt.isEmpty {
                candidateURL = destinationDir.appendingPathComponent(nextName)
            } else {
                candidateURL = destinationDir.appendingPathComponent("\(nextName).\(cleanExt)")
            }
            counter += 1
        }

        let created = fileManager.createFile(atPath: candidateURL.path, contents: Data(), attributes: nil)
        guard created else {
            throw RightClickError.fileCreationFailed(candidateURL.path)
        }

        fileRevealer([candidateURL])
        return candidateURL
    }

    // MARK: - 2. 格式化路径与剪贴板

    /// 按照指定格式拼装文件路径字符串（多选按换行分隔）
    public func formatPaths(_ urls: [URL], format: RightClickPathFormat) -> String {
        let strings: [String] = urls.compactMap { url in
            switch format {
            case .posix:
                return url.path
            case .shellEscaped:
                return Self.escapeForShell(url.path)
            case .url:
                return url.absoluteString
            case .fileName:
                return url.lastPathComponent
            }
        }
        return strings.joined(separator: "\n")
    }

    /// 复制路径到系统剪贴板
    @discardableResult
    public func copyPathsToPasteboard(_ urls: [URL], format: RightClickPathFormat) -> String {
        let text = formatPaths(urls, format: format)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }

    /// 对 Shell 路径做安全转义（处理空格、引号、特殊符号）
    public static func escapeForShell(_ path: String) -> String {
        // 如果不含任何特殊字符，直接返回
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        if path.rangeOfCharacter(from: safeCharacters.inverted) == nil {
            return path
        }
        // 采用标准单引号转义策略：'foo'\''bar'
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - 3. 移动 / 复制（带自动防冲重命名）

    /// 计算目标目录下不重名的目标 URL（若无冲突则保持原名，有冲突则加上递增编号：file (1).ext）
    public func resolveNonConflictingDestinationURL(sourceURL: URL, targetDirectoryURL: URL) -> URL {
        let originalFileName = sourceURL.lastPathComponent
        let destinationDir = ensureDirectoryURL(targetDirectoryURL)
        var candidateURL = destinationDir.appendingPathComponent(originalFileName)

        guard fileManager.fileExists(atPath: candidateURL.path) else {
            return candidateURL
        }

        let nameWithoutExt = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        var counter = 1
        while fileManager.fileExists(atPath: candidateURL.path) {
            let nextName = "\(nameWithoutExt) (\(counter))"
            if ext.isEmpty {
                candidateURL = destinationDir.appendingPathComponent(nextName)
            } else {
                candidateURL = destinationDir.appendingPathComponent("\(nextName).\(ext)")
            }
            counter += 1
        }
        return candidateURL
    }

    /// 移动文件到目标目录
    @discardableResult
    public func moveFiles(_ sourceURLs: [URL], to targetDirectoryURL: URL) throws -> [URL] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: targetDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw RightClickError.destinationNotFound(targetDirectoryURL.path)
        }

        var movedURLs: [URL] = []
        for url in sourceURLs {
            let destURL = resolveNonConflictingDestinationURL(sourceURL: url, targetDirectoryURL: targetDirectoryURL)
            do {
                try fileManager.moveItem(at: url, to: destURL)
                movedURLs.append(destURL)
            } catch {
                throw RightClickError.moveFailed("移动 \(url.lastPathComponent) 失败: \(error.localizedDescription)")
            }
        }
        return movedURLs
    }

    /// 复制文件到目标目录
    @discardableResult
    public func copyFiles(_ sourceURLs: [URL], to targetDirectoryURL: URL) throws -> [URL] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: targetDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw RightClickError.destinationNotFound(targetDirectoryURL.path)
        }

        var copiedURLs: [URL] = []
        for url in sourceURLs {
            let destURL = resolveNonConflictingDestinationURL(sourceURL: url, targetDirectoryURL: targetDirectoryURL)
            do {
                try fileManager.copyItem(at: url, to: destURL)
                copiedURLs.append(destURL)
            } catch {
                throw RightClickError.copyFailed("复制 \(url.lastPathComponent) 失败: \(error.localizedDescription)")
            }
        }
        return copiedURLs
    }

    // MARK: - 4. 调起应用（终端或代码编辑器）

    /// 在指定应用中打开目标文件或文件夹
    public func open(urls: [URL], withAppBundleIdentifier bundleId: String) throws {
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
            throw RightClickError.appLaunchFailed("未找到应用: \(bundleId)")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        workspace.open(urls, withApplicationAt: appURL, configuration: config) { _, error in
            if let error = error {
                NSLog("[OmniForge RightClick] 调起应用失败: %@", error.localizedDescription)
            }
        }
    }

    /// 调起指定路径的终端并在该目录下打开（针对不支持直接 open 目录的特定终端）
    public func openTerminal(at targetURL: URL, bundleId: String? = nil) throws {
        let dirURL = targetURL.hasDirectoryPath ? targetURL : targetURL.deletingLastPathComponent()
        
        let targetBundleId = bundleId ?? "com.apple.Terminal"
        try open(urls: [dirURL], withAppBundleIdentifier: targetBundleId)
    }

    // MARK: - 5. 切换隐藏文件可见性

    /// 切换访达隐藏文件可见性。
    /// 走访达内置快捷键 ⌘⇧.：即时生效、不重启访达，也不改动用户的 `AppleShowAllFiles` 偏好。
    /// 返回 false 表示未获辅助功能权限，快捷键未投递。
    @discardableResult
    public func toggleHiddenFiles() -> Bool {
        hiddenFilesToggler.toggleHiddenFiles()
    }
}
