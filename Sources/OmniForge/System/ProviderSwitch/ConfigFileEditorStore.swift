import Foundation

/// 配置文件原文编辑器错误。
enum ConfigFileEditorError: Error, Equatable {
    /// 内容不是合法 JSON/TOML → 拒绝保存（SPEC 2.10）。
    case invalidContent(tool: ProviderTool)
    case readFailed(path: String)
    case writeFailed(path: String)
}

/// 配置文件原文读写边界（进阶出口，SPEC 2.10）：
/// 查看并直接编辑 `settings.json` / `config.toml` 原文；
/// 保存前校验合法性，非法拒绝；保存走与切换一致的「备份 + 原子写」。
protocol ConfigFileEditing: AnyObject {
    /// 读取原文；文件缺失 → nil。
    func read(tool: ProviderTool) throws -> String?
    /// JSON/TOML 合法性校验（Claude 要求顶层为 JSON 对象）。
    func isValid(tool: ProviderTool, content: String) -> Bool
    /// 快照 + 校验 + 原子写（目标文件不存在时仅校验 + 原子写，无需备份）。
    func save(tool: ProviderTool, content: String) throws
}

final class ConfigFileEditorStore: ConfigFileEditing {
    let claudeConfigURL: URL
    let codexConfigURL: URL
    let backupStore: ProviderBackupStoring
    let fileManager: FileManager

    init(
        claudeConfigURL: URL,
        codexConfigURL: URL,
        backupStore: ProviderBackupStoring,
        fileManager: FileManager = .default
    ) {
        self.claudeConfigURL = claudeConfigURL
        self.codexConfigURL = codexConfigURL
        self.backupStore = backupStore
        self.fileManager = fileManager
    }

    private func configURL(for tool: ProviderTool) -> URL {
        switch tool {
        case .claudeCode: return claudeConfigURL
        case .codex: return codexConfigURL
        }
    }

    func read(tool: ProviderTool) throws -> String? {
        let url = configURL(for: tool)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw ConfigFileEditorError.readFailed(path: url.path)
        }
        return String(data: data, encoding: .utf8)
    }

    func isValid(tool: ProviderTool, content: String) -> Bool {
        switch tool {
        case .claudeCode:
            guard let data = content.data(using: .utf8) else { return false }
            guard let root = try? JSONSerialization.jsonObject(with: data) else { return false }
            return root is [String: Any] // settings.json 顶层必须是对象
        case .codex:
            return TOMLFile.parse(content) != nil
        }
    }

    func save(tool: ProviderTool, content: String) throws {
        let url = configURL(for: tool)
        guard isValid(tool: tool, content: content) else {
            throw ConfigFileEditorError.invalidContent(tool: tool)
        }
        guard let data = content.data(using: .utf8) else {
            throw ConfigFileEditorError.invalidContent(tool: tool)
        }
        // 与切换一致的备份 + 原子写（文件不存在时无需备份）。
        if fileManager.fileExists(atPath: url.path) {
            try? backupStore.snapshot(tool: tool, of: url)
        }
        do {
            try AtomicFileWriter.write(data, to: url, fileManager: fileManager)
        } catch {
            throw ConfigFileEditorError.writeFailed(path: url.path)
        }
    }
}
