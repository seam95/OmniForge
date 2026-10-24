import Foundation

/// 4 文件事务的 pending 意图 — 写前落盘的完整目标内容（含 token，与 profile 同等敏感）。
/// 崩溃/中断后由 `replayPendingIfPresent` 按文件顺序重放补完（幂等）。
/// 编解码走 JSONSerialization（`object` 是任意 JSON 对象，不引入 AnyCodable）。
struct ClaudeDesktopWritePending: Equatable {
    /// 单个文件的目标内容（`files` 顺序即写入顺序：profile → _meta → 3P config → 1P config）。
    /// `object` 是任意 JSON 对象（不 Equatable — 顶层 == 只比较条数与时间戳）。
    struct PendingFile {
        /// 目标文件的绝对路径（pending 与 4 文件解耦，测试可注入任意目录）。
        let path: String
        /// 完整目标 JSON 对象（非补丁 — 重放不需要读原文件）。
        let object: [String: Any]

        init(url: URL, object: [String: Any]) {
            self.path = url.path
            self.object = object
        }

        var url: URL { URL(fileURLWithPath: path) }
    }

    let files: [PendingFile]
    let createdAt: Date

    static func == (lhs: ClaudeDesktopWritePending, rhs: ClaudeDesktopWritePending) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.files.count == rhs.files.count
    }
}

/// pending 读写边界 — `<App Support>/ProviderDesktop/pending.json`（0600）。
final class ClaudeDesktopWritePendingStore {
    private let pendingURL: URL
    private let fileManager: FileManager

    init(pendingURL: URL, fileManager: FileManager = .default) {
        self.pendingURL = pendingURL
        self.fileManager = fileManager
    }

    /// 读 pending；文件缺失/损坏 → nil（损坏的 pending 无法安全重放，视为无意图；
    /// 固定写入顺序保证任何半旧状态可被下一次事务整体覆盖）。
    func load() throws -> ClaudeDesktopWritePending? {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return nil }
        guard let data = try? Data(contentsOf: pendingURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawFiles = root["files"] as? [[String: Any]] else {
            return nil
        }
        let files = rawFiles.compactMap { raw -> ClaudeDesktopWritePending.PendingFile? in
            guard let path = raw["path"] as? String,
                  let object = raw["object"] as? [String: Any] else { return nil }
            return ClaudeDesktopWritePending.PendingFile(
                url: URL(fileURLWithPath: path), object: object
            )
        }
        guard files.count == rawFiles.count else { return nil }
        let createdAt = (root["createdAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        return ClaudeDesktopWritePending(files: files, createdAt: createdAt)
    }

    /// 写 pending（0600，原子）。
    func save(_ pending: ClaudeDesktopWritePending) throws {
        let root: [String: Any] = [
            "files": pending.files.map { ["path": $0.path, "object": $0.object] },
            "createdAt": pending.createdAt.timeIntervalSince1970,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.write(data, to: pendingURL, fileManager: fileManager)
    }

    /// 删除 pending（事务完成的最后一步）。
    func clear() throws {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        try fileManager.removeItem(at: pendingURL)
    }
}
