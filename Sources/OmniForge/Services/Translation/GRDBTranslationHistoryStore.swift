import Foundation
import GRDB

/// 翻译历史的 GRDB 生产实现。
///
/// 使用 actor 串行化数据库访问，避免同步磁盘 I/O 落到主 actor（视图动作）。
/// 与便签等既有存储的“失败静默降级”不同：初始化、读取、写入与删除失败都向调用者抛出，
/// 由上层决定如何提示，绝不把失败伪装成空历史。
actor GRDBTranslationHistoryStore: TranslationHistoryStoring {
    /// 数据库文件路径，由调用方决定（生产为 Application Support/OmniForge/Translation/history.sqlite）。
    private let databaseURL: URL
    /// 延迟到 actor 内首次访问时才打开，避免在调用方（可能主 actor）执行同步磁盘初始化。
    private var databaseQueue: DatabaseQueue?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    // MARK: - TranslationHistoryStoring

    func load(limit: Int) async throws -> [TranslationHistoryEntry] {
        // SQLite 的负数 LIMIT 表示“不限制”；这里显式返回空，避免调用方失误时误读全表。
        guard limit > 0 else { return [] }

        let queue = try resolvedQueue()
        // 读取在数据库队列执行。返回可发送的记录数组，再在 actor 内映射为领域模型。
        let records = try await queue.read { db in
            try TranslationHistoryRecord
                .order(Column("completedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        // 单条记录损坏（例如外部篡改）只跳过该条，避免一条坏数据让整个历史不可用；
        // 数据库访问失败仍通过上面的 try 向上抛出。
        return records.compactMap { $0.toEntry() }
    }

    func insertAndPrune(_ entry: TranslationHistoryEntry, limit: Int) async throws {
        // 异步排队后、开始写入前检查取消：已取消的任务一律不落库。
        try Task.checkCancellation()

        let queue = try resolvedQueue()
        let record = TranslationHistoryRecord(entry: entry)
        // 数据库写队列闭包不在任务上下文中执行，无法直接读 `Task.isCancelled`；
        // 用取消处理器把取消状态同步写入线程安全标志，供事务内检查。
        let cancellation = CancellationFlag()

        try await withTaskCancellationHandler {
            try await queue.write { db in
                // 插入前检查：排队等待期间被取消则直接放弃整个写事务。
                if cancellation.isCancelled { throw CancellationError() }

                // 插入与裁剪在同一写事务内：GRDB 的 write 默认包裹事务，二者要么都生效，要么都回滚。
                try record.insert(db)
                if limit > 0 {
                    try Self.prune(db, keepingNewest: limit)
                }

                // 提交前最终检查：此处抛出会让 GRDB 回滚写事务，已插入记录不会落库。
                if cancellation.isCancelled { throw CancellationError() }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func delete(id: UUID) async throws {
        let queue = try resolvedQueue()
        // 删除失败必须抛出，不静默；删除不存在的 id 属于幂等成功。
        try await queue.write { db in
            try TranslationHistoryRecord
                .filter(Column("id") == id.uuidString)
                .deleteAll(db)
        }
    }

    func deleteAll() async throws {
        let queue = try resolvedQueue()
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM translationHistory")
        }
    }

    // MARK: - 数据库初始化

    /// 延迟打开数据库并执行迁移。
    ///
    /// 首次访问发生在 actor 的隔离上下文，不阻塞主 actor；打开失败每次操作都会重试并抛出，
    /// 不做缓存式降级，保证磁盘恢复后功能可用。
    private func resolvedQueue() throws -> DatabaseQueue {
        if let databaseQueue { return databaseQueue }

        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try Self.databaseMigrator.migrate(queue)
        databaseQueue = queue
        return queue
    }

    private static var databaseMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createTranslationHistory") { db in
            try db.create(table: "translationHistory") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("requestText", .text).notNull()
                t.column("resultText", .text).notNull()
                t.column("sourceLanguage", .text).notNull()
                t.column("targetLanguage", .text).notNull()
                t.column("engine", .text).notNull()
                // 仅 AI 引擎有模型名；系统翻译为 NULL。
                t.column("model", .text)
                // Unix 时间戳（秒），与既有存储的时间列一致。
                t.column("completedAt", .double).notNull()
            }
            // 列表展示与容量裁剪都按完成时间倒序、id 倒序稳定排序，为该顺序建索引。
            try db.execute(sql: """
                CREATE INDEX translationHistoryOnCompletedAt
                ON translationHistory (completedAt DESC, id DESC)
                """)
        }
        return migrator
    }

    /// 保留完成时间最新（同时间按 id 倒序）的 `limit` 条记录，删除其余记录。
    ///
    /// 由调用方在写事务内调用，保证与插入同事务提交或回滚。
    /// 注意：id 为主键且非空，`NOT IN` 子查询不会遇到 NULL 陷阱。
    private static func prune(_ db: Database, keepingNewest limit: Int) throws {
        try db.execute(
            sql: """
                DELETE FROM translationHistory
                WHERE id NOT IN (
                    SELECT id FROM translationHistory
                    ORDER BY completedAt DESC, id DESC
                    LIMIT ?
                )
                """,
            arguments: [limit]
        )
    }
}

// MARK: - 数据库记录

/// 历史表的行映射。字段与 `TranslationHistoryEntry` 对应，时间以 Unix 时间戳存储。
private struct TranslationHistoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "translationHistory"

    var id: String
    var requestText: String
    var resultText: String
    var sourceLanguage: String
    var targetLanguage: String
    var engine: String
    var model: String?
    var completedAt: Double

    init(entry: TranslationHistoryEntry) {
        self.id = entry.id.uuidString
        self.requestText = entry.request.text
        self.resultText = entry.result.text
        // 实际使用的语言以结果为准（进入引擎前请求已解析出具体语言，成功结果沿用同一对语言）。
        self.sourceLanguage = entry.result.sourceLanguage
        self.targetLanguage = entry.result.targetLanguage
        self.engine = entry.result.engine.rawValue
        self.model = entry.result.model
        self.completedAt = entry.completedAt.timeIntervalSince1970
    }

    /// 重建领域模型；UUID 或引擎标识非法时返回 nil（视为损坏记录）。
    func toEntry() -> TranslationHistoryEntry? {
        guard let uuid = UUID(uuidString: id),
              let engine = TranslationEngineID(rawValue: engine) else {
            return nil
        }
        let request = TranslationRequest(
            id: uuid,
            text: requestText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        let result = TranslationResult(
            text: resultText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            engine: engine,
            model: model
        )
        return TranslationHistoryEntry(
            id: uuid,
            request: request,
            result: result,
            completedAt: Date(timeIntervalSince1970: completedAt)
        )
    }
}

// MARK: - 取消标志

/// 跨线程取消标志：由 `@Sendable` 取消处理器写入，由数据库写队列闭包安全读取。
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
