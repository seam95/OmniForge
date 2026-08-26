import Foundation

/// 配置写入前的快照 — 带时间戳，按工具保留最近 10 份（SPEC 2.5）。
struct ProviderBackup: Identifiable, Equatable {
    let id: String // 文件名（如 `claudeCode-2026-08-26_12-00-00-1A2B3C4D.json`）
    let tool: ProviderTool
    let date: Date
    /// 排序用：实际文件修改时间（文件名时间戳精度到秒，同秒内靠修改时间区分先后）。
    var sortDate: Date = .distantPast
}

/// 备份存储边界。
protocol ProviderBackupStoring: AnyObject {
    /// 对目标配置文件做带时间戳快照；按工具保留最近 10 份（超出删最旧）。
    /// 返回新快照。
    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup
    /// 按工具列出历史快照（最新在前）。
    func list(tool: ProviderTool) -> [ProviderBackup]
    /// 恢复指定快照：快照内容经 tmp+rename 原子写回目标配置文件（`0600`）。
    func restore(_ backup: ProviderBackup, to configURL: URL) throws
}

/// `~/Library/Application Support/OmniForge/ProviderSwitchBackups/` 快照实现。
final class ProviderBackupStore: ProviderBackupStoring {
    /// 每工具保留份数（SPEC 2.5）。
    static let retentionLimit = 10

    let backupDirectory: URL
    let fileManager: FileManager

    init(backupDirectory: URL, fileManager: FileManager = .default) {
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
    }

    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw ProviderBackupError.sourceMissing(path: configURL.path)
        }
        let data = try Data(contentsOf: configURL)
        let backup = ProviderBackup(
            id: Self.makeSnapshotFileName(tool: tool, extensionName: configURL.pathExtension),
            tool: tool,
            date: Date()
        )
        let destination = backupDirectory.appendingPathComponent(backup.id)
        try AtomicFileWriter.write(data, to: destination, fileManager: fileManager)
        enforceRetention(tool: tool)
        return backup
    }

    func list(tool: ProviderTool) -> [ProviderBackup] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" || $0.pathExtension == "toml" }
            .compactMap { url -> ProviderBackup? in
                guard var backup = Self.parse(fileName: url.lastPathComponent) else { return nil }
                if let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate {
                    backup.sortDate = modificationDate
                }
                return backup
            }
            .filter { $0.tool == tool }
            .sorted { $0.sortDate > $1.sortDate }
    }

    func restore(_ backup: ProviderBackup, to configURL: URL) throws {
        let source = backupDirectory.appendingPathComponent(backup.id)
        guard fileManager.fileExists(atPath: source.path) else {
            throw ProviderBackupError.backupMissing(path: source.path)
        }
        let data = try Data(contentsOf: source)
        try AtomicFileWriter.write(data, to: configURL, fileManager: fileManager)
    }

    // MARK: - private

    /// 快照文件名：`<tool>-<UTC时间戳>-<随机4位hex>.<扩展名>`（固定宽度前缀保证按名排序 = 按时间排序）。
    static func makeSnapshotFileName(tool: ProviderTool, extensionName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let suffix = String(format: "%04X", Int.random(in: 0...0xFFFF))
        return "\(tool.rawValue)-\(formatter.string(from: Date()))-\(suffix).\(extensionName)"
    }

    static func parse(fileName: String) -> ProviderBackup? {
        let parts = fileName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let tool = ProviderTool(rawValue: String(parts[0])) else { return nil }
        let rest = String(parts[1])
        guard let dot = rest.lastIndex(of: ".") else { return nil }
        let timestampAndSuffix = String(rest[rest.startIndex..<dot])
        let timestamp = String(timestampAndSuffix.prefix(19)) // yyyy-MM-dd_HH-mm-ss
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = formatter.date(from: timestamp) else { return nil }
        return ProviderBackup(id: fileName, tool: tool, date: date)
    }

    /// 保留最近 10 份：按文件名（时间戳）升序删除超出的最旧快照。
    private func enforceRetention(tool: ProviderTool) {
        let existing = list(tool: tool)
        guard existing.count > Self.retentionLimit else { return }
        for stale in existing.suffix(existing.count - Self.retentionLimit) {
            try? fileManager.removeItem(
                at: backupDirectory.appendingPathComponent(stale.id)
            )
        }
    }
}

/// 备份错误。
enum ProviderBackupError: Error, Equatable {
    case sourceMissing(path: String)
    case backupMissing(path: String)
}
