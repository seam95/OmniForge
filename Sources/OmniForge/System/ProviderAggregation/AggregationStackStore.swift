import Foundation

/// 聚合名单与登记簿持久化边界。
protocol AggregationStackStoring: AnyObject {
    func load() -> AggregationStack
    func save(_ stack: AggregationStack) throws
}

/// App Support 下的 `stack.json` 读写：缺失当空栈、损坏隔离（不 throw）、原子写 0600。
final class AggregationStackStore: AggregationStackStoring {
    private let stackURL: URL
    private let fileManager: FileManager

    init(stackURL: URL, fileManager: FileManager = .default) {
        self.stackURL = stackURL
        self.fileManager = fileManager
    }

    func load() -> AggregationStack {
        guard fileManager.fileExists(atPath: stackURL.path),
              let data = try? Data(contentsOf: stackURL) else {
            return AggregationStack()
        }
        do {
            return try JSONDecoder().decode(AggregationStack.self, from: data)
        } catch {
            // 损坏不硬写：隔离原文件后当空栈，下次启动不再撞同一份坏数据。
            quarantine()
            return AggregationStack()
        }
    }

    func save(_ stack: AggregationStack) throws {
        try fileManager.createDirectory(
            at: stackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stack)
        try AtomicFileWriter.write(data, to: stackURL, fileManager: fileManager)
    }

    /// 损坏隔离：移到同目录 `<文件名>.corrupt-<UTC 时间戳（毫秒精度，防同刻二次隔离撞名）>`。
    private func quarantine() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let target = stackURL.deletingLastPathComponent()
            .appendingPathComponent("\(stackURL.lastPathComponent).corrupt-\(stamp)")
        try? fileManager.moveItem(at: stackURL, to: target)
    }
}
