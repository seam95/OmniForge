import Foundation

/// 写前意图持久化边界。
protocol AggregationPendingStoring: AnyObject {
    func load() -> AggregationPending?
    func save(_ pending: AggregationPending) throws
    func clear() throws
}

/// App Support 下的 `pending.json` 读写：缺失 → nil；损坏隔离到 `.corrupt-<UTC>` 后返回 nil。
final class AggregationPendingStore: AggregationPendingStoring {
    private let pendingURL: URL
    private let fileManager: FileManager

    init(pendingURL: URL, fileManager: FileManager = .default) {
        self.pendingURL = pendingURL
        self.fileManager = fileManager
    }

    func load() -> AggregationPending? {
        guard fileManager.fileExists(atPath: pendingURL.path),
              let data = try? Data(contentsOf: pendingURL) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(AggregationPending.self, from: data)
        } catch {
            quarantine()
            return nil
        }
    }

    func save(_ pending: AggregationPending) throws {
        try fileManager.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pending)
        try AtomicFileWriter.write(data, to: pendingURL, fileManager: fileManager)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        try fileManager.removeItem(at: pendingURL)
    }

    /// 恢复判定：`published == true` → 前滚（已有客户端文件落地，必须补完到新名单）；
    /// `false` → 丢弃（什么都没发布，回到原状）。
    static func recovery(for pending: AggregationPending) -> AggregationRecovery {
        pending.published ? .rolledForward : .discarded
    }

    /// 损坏隔离：移到同目录 `<文件名>.corrupt-<UTC 时间戳（毫秒精度）>`。
    private func quarantine() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let target = pendingURL.deletingLastPathComponent()
            .appendingPathComponent("\(pendingURL.lastPathComponent).corrupt-\(stamp)")
        try? fileManager.moveItem(at: pendingURL, to: target)
    }
}
