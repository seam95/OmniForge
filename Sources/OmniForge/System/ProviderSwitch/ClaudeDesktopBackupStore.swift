import Foundation

/// Desktop bundle 备份存储边界（独立类型，不改单文件 `ProviderBackupStoring` 协议，
/// SPEC 关键设计决策 3）：一份快照 = 4 个文件的 JSON bundle（缺失记 absent）。
protocol ClaudeDesktopBackupStoring: AnyObject {
    /// 对 Desktop 的 4 个配置文件做 bundle 快照（源文件缺失记 absent，不抛错）。
    func snapshot4Files() throws -> ProviderBackup
    /// 按工具列出历史快照（最新在前）。
    func list(tool: ProviderTool) -> [ProviderBackup]
    /// 读取 bundle 的格式化 JSON（恢复前预览）。
    func content(of backup: ProviderBackup) throws -> String
    /// 恢复：absent 的文件删除，其余原子写回 4 个固定路径。
    func restore(_ backup: ProviderBackup) throws
}

/// bundle 快照实现：目录 `<App Support>/ProviderSwitchBackups/`（与单文件快照同目录、
/// 不同的文件扩展名 `.bundle.json`），同一 10 份保留策略。
final class ClaudeDesktopBackupStore: ClaudeDesktopBackupStoring {
    static let retentionLimit = 10
    static let bundleExtension = "bundle.json"

    private let configURL: URL
    private let config3PURL: URL
    private let profileURL: URL
    private let metaURL: URL
    private let backupDirectory: URL
    private let fileManager: FileManager

    init(
        configURL: URL,
        config3PURL: URL,
        profileURL: URL,
        metaURL: URL,
        backupDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.config3PURL = config3PURL
        self.profileURL = profileURL
        self.metaURL = metaURL
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
    }

    /// 生产装配。
    static func production(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) -> ClaudeDesktopBackupStore {
        ClaudeDesktopBackupStore(
            configURL: ProviderSwitchPaths.claudeDesktopConfigURL(homePath: homePath),
            config3PURL: ProviderSwitchPaths.claudeDesktop3PConfigURL(homePath: homePath),
            profileURL: ProviderSwitchPaths.claudeDesktopProfileURL(homePath: homePath),
            metaURL: ProviderSwitchPaths.claudeDesktopMetaURL(homePath: homePath),
            backupDirectory: ProviderSwitchPaths.backupDirectory(applicationSupportRoot: applicationSupportRoot),
            fileManager: fileManager
        )
    }

    // MARK: - 快照

    func snapshot4Files() throws -> ProviderBackup {
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let targets: [(key: String, url: URL)] = [
            ("config1P", configURL),
            ("config3P", config3PURL),
            ("profile", profileURL),
            ("meta", metaURL),
        ]
        var files: [[String: Any]] = []
        for target in targets {
            if fileManager.fileExists(atPath: target.url.path),
               let data = try? Data(contentsOf: target.url),
               let text = String(data: data, encoding: .utf8) {
                files.append(["key": target.key, "path": target.url.path, "content": text])
            } else {
                files.append(["key": target.key, "path": target.url.path, "absent": true])
            }
        }
        let bundle: [String: Any] = [
            "tool": ProviderTool.claudeDesktop.rawValue,
            "createdAt": Date().timeIntervalSince1970,
            "files": files,
        ]
        let backup = ProviderBackup(
            id: Self.makeSnapshotFileName(),
            tool: .claudeDesktop,
            date: Date()
        )
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: backupDirectory.appendingPathComponent(backup.id), fileManager: fileManager)
        enforceRetention()
        return backup
    }

    func list(tool: ProviderTool) -> [ProviderBackup] {
        guard tool == .claudeDesktop else { return [] }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }
        return urls
            .filter { $0.lastPathComponent.hasSuffix(".\(Self.bundleExtension)") }
            .compactMap { url -> ProviderBackup? in
                guard var backup = Self.parse(fileName: url.lastPathComponent) else { return nil }
                if let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate {
                    backup.sortDate = modificationDate
                }
                return backup
            }
            .sorted { $0.sortDate > $1.sortDate }
    }

    func content(of backup: ProviderBackup) throws -> String {
        let source = backupDirectory.appendingPathComponent(backup.id)
        guard let data = try? Data(contentsOf: source) else {
            throw ProviderBackupError.backupMissing(path: source.path)
        }
        // 预览文本 = bundle 格式化 JSON（不展开单文件内容）。
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderBackupError.backupMissing(path: source.path)
        }
        let formatted = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(data: formatted, encoding: .utf8) ?? ""
    }

    func restore(_ backup: ProviderBackup) throws {
        let source = backupDirectory.appendingPathComponent(backup.id)
        guard let data = try? Data(contentsOf: source),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            throw ProviderBackupError.backupMissing(path: source.path)
        }
        for file in files {
            guard let path = file["path"] as? String else { continue }
            let target = URL(fileURLWithPath: path)
            if file["absent"] as? Bool == true {
                // 快照时不存在 → 恢复为不存在（删除后来才出现的文件）。
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                continue
            }
            guard let text = file["content"] as? String, let content = text.data(using: .utf8) else { continue }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFileWriter.write(content, to: target, fileManager: fileManager)
        }
    }

    // MARK: - private

    /// 快照文件名：`claudeDesktop-<UTC时间戳>-<随机4位hex>.bundle.json`（与单文件快照同构）。
    static func makeSnapshotFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = String(format: "%04X", Int.random(in: 0...0xFFFF))
        return "claudeDesktop-\(formatter.string(from: Date()))-\(suffix).\(bundleExtension)"
    }

    static func parse(fileName: String) -> ProviderBackup? {
        let prefix = "claudeDesktop-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".\(bundleExtension)") else { return nil }
        let rest = String(fileName.dropFirst(prefix.count))
        let timestamp = String(rest.prefix(19)) // yyyy-MM-dd_HH-mm-ss
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = formatter.date(from: timestamp) else { return nil }
        return ProviderBackup(id: fileName, tool: .claudeDesktop, date: date)
    }

    private func enforceRetention() {
        let existing = list(tool: .claudeDesktop)
        guard existing.count > Self.retentionLimit else { return }
        for stale in existing.suffix(existing.count - Self.retentionLimit) {
            try? fileManager.removeItem(at: backupDirectory.appendingPathComponent(stale.id))
        }
    }
}
