import Foundation
import GRDB

/// GRDB 用量存储 — `~/Library/Application Support/app.omniforge/TokenUsage/usage.sqlite`。
///
/// 表：
/// - `usage_buckets`：主键 (provider, model, bucket_start)，累计快照 INSERT OR REPLACE（幂等）。
/// - `message_seen`：已见去重 key（LRU 封顶）。
/// - `file_cursors`：文件 {inode, offset} 字节游标。
/// 隐私红线：表内只有 token 数字、时间与 key 哈希字符串，绝无会话正文。
final class GRDBUsageStore: UsageStoring {
    /// 生产默认根目录：`~/Library/Application Support/app.omniforge`。
    static let defaultApplicationSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("app.omniforge", isDirectory: true)
    }()

    static let relativeDirectory = "TokenUsage"
    static let databaseFileName = "usage.sqlite"

    static var defaultDatabaseURL: URL {
        defaultApplicationSupportDirectory
            .appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(databaseFileName, isDirectory: false)
    }

    private let databaseQueue: DatabaseQueue?
    private let maxSeenKeys: Int

    /// - Parameters:
    ///   - databaseURL: SQLite 文件位置；父目录自动创建（0700），文件权限 0600。
    ///   - maxSeenKeys: 已见去重集合容量上限（LRU 淘汰）。
    init(
        databaseURL: URL,
        maxSeenKeys: Int = UsageStorePolicy.maxSeenKeys,
        fileManager: FileManager = .default
    ) {
        self.maxSeenKeys = maxSeenKeys
        do {
            let directory = databaseURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let queue = try DatabaseQueue(path: databaseURL.path)
            try Self.makeMigrator().migrate(queue)
            // 隐私红线：数据落盘权限 0600。
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            self.databaseQueue = queue
        } catch {
            print("[GRDBUsageStore] Failed to initialize database: \(error)")
            self.databaseQueue = nil
        }
    }

    // MARK: - 桶

    func upsertBucket(_ state: UsageBucketState) {
        guard let databaseQueue else { return }
        let key = state.key
        let usage = state.usage
        do {
            try databaseQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO usage_buckets
                        (provider, model, bucket_start, input_tokens, cached_input_tokens,
                         cache_creation_input_tokens, output_tokens, reasoning_output_tokens,
                         total_tokens, conversation_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        key.provider.rawValue, key.model, key.bucketStart.timeIntervalSince1970,
                        usage.inputTokens, usage.cachedInputTokens, usage.cacheCreationInputTokens,
                        usage.outputTokens, usage.reasoningOutputTokens, usage.totalTokens,
                        state.conversationCount,
                    ]
                )
            }
        } catch {
            print("[GRDBUsageStore] upsertBucket failed: \(error)")
        }
    }

    func loadBucket(_ key: UsageBucketKey) -> UsageBucketState? {
        guard let databaseQueue else { return nil }
        do {
            return try databaseQueue.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM usage_buckets
                    WHERE provider = ? AND model = ? AND bucket_start = ?
                    """,
                    arguments: [key.provider.rawValue, key.model, key.bucketStart.timeIntervalSince1970]
                )
                return row.map(Self.makeBucketState)
            }
        } catch {
            print("[GRDBUsageStore] loadBucket failed: \(error)")
            return nil
        }
    }

    func loadBuckets(
        from start: Date,
        to end: Date,
        providers: Set<TokenUsageProvider>?
    ) -> [UsageBucketState] {
        guard let databaseQueue else { return [] }
        do {
            return try databaseQueue.read { db in
                let rows: [Row]
                if let providers, !providers.isEmpty {
                    let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
                    let arguments: StatementArguments = StatementArguments(
                        [start.timeIntervalSince1970, end.timeIntervalSince1970]
                    ) + StatementArguments(providers.map(\.rawValue))
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT * FROM usage_buckets
                        WHERE bucket_start >= ? AND bucket_start < ? AND provider IN (\(placeholders))
                        ORDER BY bucket_start
                        """,
                        arguments: arguments
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT * FROM usage_buckets
                        WHERE bucket_start >= ? AND bucket_start < ?
                        ORDER BY bucket_start
                        """,
                        arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
                    )
                }
                return rows.map(Self.makeBucketState)
            }
        } catch {
            print("[GRDBUsageStore] loadBuckets failed: \(error)")
            return []
        }
    }

    // MARK: - 聚合查询（仪表盘重设计）

    /// 按本地日 × provider 聚合（`GROUP BY day, provider`）。
    /// 本地日界用 `date(bucket_start,'unixepoch','localtime')`（与 Swift 侧
    /// `calendar.startOfDay` 口径一致）；行少（每活跃日×provider 一行），
    /// 避免把整年半小时桶读进内存。解析失败的日串行丢弃。
    func loadDailyAggregates(
        from start: Date,
        to end: Date,
        providers: Set<TokenUsageProvider>?
    ) -> [UsageDayProviderAggregate] {
        guard let databaseQueue else { return [] }
        do {
            return try databaseQueue.read { db in
                let rows: [Row]
                if let providers, !providers.isEmpty {
                    let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
                    let arguments: StatementArguments = StatementArguments(
                        [start.timeIntervalSince1970, end.timeIntervalSince1970]
                    ) + StatementArguments(providers.map(\.rawValue))
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT date(bucket_start, 'unixepoch', 'localtime') AS day,
                               provider,
                               SUM(total_tokens) AS total_tokens,
                               SUM(conversation_count) AS conversation_count
                        FROM usage_buckets
                        WHERE bucket_start >= ? AND bucket_start < ? AND provider IN (\(placeholders))
                        GROUP BY day, provider
                        ORDER BY day
                        """,
                        arguments: arguments
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT date(bucket_start, 'unixepoch', 'localtime') AS day,
                               provider,
                               SUM(total_tokens) AS total_tokens,
                               SUM(conversation_count) AS conversation_count
                        FROM usage_buckets
                        WHERE bucket_start >= ? AND bucket_start < ?
                        GROUP BY day, provider
                        ORDER BY day
                        """,
                        arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
                    )
                }
                return rows.compactMap(Self.makeDayAggregate)
            }
        } catch {
            print("[GRDBUsageStore] loadDailyAggregates failed: \(error)")
            return []
        }
    }

    /// 按模型聚合（`GROUP BY model`，按总量降序）。
    func loadModelAggregates(
        from start: Date,
        to end: Date,
        providers: Set<TokenUsageProvider>?
    ) -> [UsageModelAggregate] {
        guard let databaseQueue else { return [] }
        do {
            return try databaseQueue.read { db in
                let rows: [Row]
                if let providers, !providers.isEmpty {
                    let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
                    let arguments: StatementArguments = StatementArguments(
                        [start.timeIntervalSince1970, end.timeIntervalSince1970]
                    ) + StatementArguments(providers.map(\.rawValue))
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT model, SUM(total_tokens) AS sum_total_tokens
                        FROM usage_buckets
                        WHERE bucket_start >= ? AND bucket_start < ? AND provider IN (\(placeholders))
                        GROUP BY model
                        ORDER BY sum_total_tokens DESC
                        """,
                        arguments: arguments
                    )
                } else {
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT model, SUM(total_tokens) AS sum_total_tokens
                        FROM usage_buckets
                        WHERE bucket_start >= ? AND bucket_start < ?
                        GROUP BY model
                        ORDER BY sum_total_tokens DESC
                        """,
                        arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
                    )
                }
                return rows.map(Self.makeModelAggregate)
            }
        } catch {
            print("[GRDBUsageStore] loadModelAggregates failed: \(error)")
            return []
        }
    }

    // MARK: - 已见 key

    func loadSeenKeys() -> Set<String> {
        guard let databaseQueue else { return [] }
        do {
            return try databaseQueue.read { db in
                Set(try String.fetchAll(db, sql: "SELECT key FROM message_seen"))
            }
        } catch {
            print("[GRDBUsageStore] loadSeenKeys failed: \(error)")
            return []
        }
    }

    func storeSeenKeys(_ keys: Set<String>, asOf date: Date) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                for key in keys {
                    try db.execute(
                        sql: """
                        INSERT OR REPLACE INTO message_seen (key, seen_at) VALUES (?, ?)
                        """,
                        arguments: [key, date.timeIntervalSince1970]
                    )
                }
                try trimSeenKeys(db)
            }
        } catch {
            print("[GRDBUsageStore] storeSeenKeys failed: \(error)")
        }
    }

    private func trimSeenKeys(_ db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_seen") ?? 0
        let excess = count - maxSeenKeys
        guard excess > 0 else { return }
        try db.execute(
            sql: """
            DELETE FROM message_seen WHERE key IN (
                SELECT key FROM message_seen ORDER BY seen_at ASC, key ASC LIMIT ?
            )
            """,
            arguments: [excess]
        )
    }

    // MARK: - 游标

    func loadCursors() -> [String: JSONLCursor] {
        guard let databaseQueue else { return [:] }
        do {
            let rows = try databaseQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT path, inode, offset, model FROM file_cursors")
            }
            var cursors: [String: JSONLCursor] = [:]
            for row in rows {
                cursors[row["path"] as String] = JSONLCursor(
                    inode: UInt64(row["inode"] as Int64),
                    offset: UInt64(row["offset"] as Int64),
                    model: row["model"] as? String
                )
            }
            return cursors
        } catch {
            print("[GRDBUsageStore] loadCursors failed: \(error)")
            return [:]
        }
    }

    func storeCursor(path: String, cursor: JSONLCursor) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO file_cursors (path, inode, offset, model) VALUES (?, ?, ?, ?)
                    """,
                    arguments: [path, Int64(cursor.inode), Int64(cursor.offset), cursor.model]
                )
            }
        } catch {
            print("[GRDBUsageStore] storeCursor failed: \(error)")
        }
    }

    func removeCursor(path: String) {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM file_cursors WHERE path = ?", arguments: [path])
            }
        } catch {
            print("[GRDBUsageStore] removeCursor failed: \(error)")
        }
    }

    func clearCursors() {
        guard let databaseQueue else { return }
        do {
            try databaseQueue.write { db in
                try db.execute(sql: "DELETE FROM file_cursors")
            }
        } catch {
            print("[GRDBUsageStore] clearCursors failed: \(error)")
        }
    }

    // MARK: - 提供者消息级状态（SQLite 差分采集）

    /// 每 provider 状态条数上限（超出按写入顺序截断，对齐 seen 容量语义）。
    static let maxMessageStatePerProvider = 200_000

    func loadProviderMessageState(_ provider: TokenUsageProvider) -> [String: String] {
        guard let databaseQueue else { return [:] }
        do {
            return try databaseQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT message_key, payload FROM provider_message_state WHERE provider = ?",
                    arguments: [provider.rawValue]
                )
                var state: [String: String] = [:]
                for row in rows {
                    state[row["message_key"] as String] = row["payload"] as String
                }
                return state
            }
        } catch {
            print("[GRDBUsageStore] loadProviderMessageState failed: \(error)")
            return [:]
        }
    }

    func storeProviderMessageState(_ provider: TokenUsageProvider, entries: [String: String]) {
        guard let databaseQueue, !entries.isEmpty else { return }
        do {
            try databaseQueue.write { db in
                let now = Date().timeIntervalSince1970
                for (key, payload) in entries {
                    try db.execute(
                        sql: """
                        INSERT OR REPLACE INTO provider_message_state (provider, message_key, payload, updated_at)
                        VALUES (?, ?, ?, ?)
                        """,
                        arguments: [provider.rawValue, key, payload, now]
                    )
                }
                try trimProviderMessageState(db, provider: provider)
            }
        } catch {
            print("[GRDBUsageStore] storeProviderMessageState failed: \(error)")
        }
    }

    private func trimProviderMessageState(_ db: Database, provider: TokenUsageProvider) throws {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM provider_message_state WHERE provider = ?",
            arguments: [provider.rawValue]
        ) ?? 0
        let excess = count - Self.maxMessageStatePerProvider
        guard excess > 0 else { return }
        try db.execute(
            sql: """
            DELETE FROM provider_message_state WHERE provider = ? AND message_key IN (
                SELECT message_key FROM provider_message_state WHERE provider = ?
                ORDER BY updated_at ASC, message_key ASC LIMIT ?
            )
            """,
            arguments: [provider.rawValue, provider.rawValue, excess]
        )
    }

    // MARK: - Schema

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createUsageBuckets") { db in
            try db.create(table: "usage_buckets") { t in
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("bucket_start", .double).notNull()
                t.column("input_tokens", .integer).notNull()
                t.column("cached_input_tokens", .integer).notNull()
                t.column("cache_creation_input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("reasoning_output_tokens", .integer).notNull()
                t.column("total_tokens", .integer).notNull()
                t.column("conversation_count", .integer).notNull()
                t.primaryKey(["provider", "model", "bucket_start"])
            }
        }
        migrator.registerMigration("createSeenKeys") { db in
            try db.create(table: "message_seen") { t in
                t.column("key", .text).notNull().primaryKey()
                t.column("seen_at", .double).notNull()
            }
        }
        migrator.registerMigration("createFileCursors") { db in
            try db.create(table: "file_cursors") { t in
                t.column("path", .text).notNull().primaryKey()
                t.column("inode", .integer).notNull()
                t.column("offset", .integer).notNull()
            }
        }
        // Kimi Code 增量续读的模型归属（config.update 可能在游标偏移之下）。
        migrator.registerMigration("addFileCursorModel") { db in
            try db.alter(table: "file_cursors") { t in
                t.add(column: "model", .text)
            }
        }
        // Gemini → Antigravity 替换：清理 gemini 历史桶行，避免聚合口径出现幽灵 provider。
        migrator.registerMigration("removeGeminiBuckets") { db in
            _ = try db.execute(sql: "DELETE FROM usage_buckets WHERE provider = ?", arguments: ["gemini"])
        }
        // 多供应商接入（2026-08-24，期 3）：SQLite 差分采集的消息级状态账本。
        migrator.registerMigration("createProviderMessageState") { db in
            try db.create(table: "provider_message_state") { t in
                t.column("provider", .text).notNull()
                t.column("message_key", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("updated_at", .double).notNull()
                t.primaryKey(["provider", "message_key"])
            }
        }
        return migrator
    }

    private static func makeBucketState(from row: Row) -> UsageBucketState {
        guard let provider = TokenUsageProvider(rawValue: row["provider"] as String) else {
            return UsageBucketState(
                key: UsageBucketKey(provider: .claude, model: "unknown", bucketStart: Date()),
                usage: .zero,
                conversationCount: 0
            )
        }
        let key = UsageBucketKey(
            provider: provider,
            model: row["model"] as String,
            bucketStart: Date(timeIntervalSince1970: row["bucket_start"] as Double)
        )
        let usage = TokenUsage(
            inputTokens: Int(row["input_tokens"] as Int64),
            cachedInputTokens: Int(row["cached_input_tokens"] as Int64),
            cacheCreationInputTokens: Int(row["cache_creation_input_tokens"] as Int64),
            outputTokens: Int(row["output_tokens"] as Int64),
            reasoningOutputTokens: Int(row["reasoning_output_tokens"] as Int64),
            totalTokens: Int(row["total_tokens"] as Int64)
        )
        return UsageBucketState(
            key: key,
            usage: usage,
            conversationCount: Int(row["conversation_count"] as Int64)
        )
    }

    private static func makeDayAggregate(from row: Row) -> UsageDayProviderAggregate? {
        guard let provider = TokenUsageProvider(rawValue: row["provider"] as String) else { return nil }
        return UsageDayProviderAggregate(
            localDay: row["day"] as String,
            provider: provider,
            totalTokens: Int(row["total_tokens"] as Int64),
            conversations: Int(row["conversation_count"] as Int64)
        )
    }

    private static func makeModelAggregate(from row: Row) -> UsageModelAggregate {
        UsageModelAggregate(
            model: row["model"] as String,
            totalTokens: Int(row["sum_total_tokens"] as Int64)
        )
    }
}
