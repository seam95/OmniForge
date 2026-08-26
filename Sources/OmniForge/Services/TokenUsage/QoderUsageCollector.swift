import Combine
import Foundation
import GRDB

/// qoder 用量采集器（B 类 SQLite）。
///
/// 数据源：`~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db`
/// （`$QODER_HOME` / `$QODER_DB_PATH` 覆盖）。SQL：
/// JOIN chat_message / chat_record / chat_session，只取 assistant 且有 token_info 的行。
///
/// 差分语义（PLAN §3.4）：**变化整行减旧加新**（非逐列差分）——状态账本记上次入桶的
/// 全量 totals/bucket/model；请求级会话归属（每条 request 只计 1 会话）每次从完整
/// 有序快照重算。
///
/// 隐私红线（SPEC 2.6）：DB 只读打开；只读 token_info / 模型 / gmt_create 等字段。
final class QoderUsageCollector: SQLiteUsageCollectorBase {
    static func defaultDatabaseURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["QODER_DB_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let root: URL
        if let override = environment["QODER_HOME"], !override.isEmpty {
            root = URL(fileURLWithPath: override)
        } else {
            root = URL(fileURLWithPath: homePath + "/Library/Application Support/Qoder")
        }
        return root.appendingPathComponent("SharedClientCache/cache/db/local.db")
    }

    private static let qoderUsageSQL = """
    SELECT
      cm.rowid AS row_id,
      cm.id,
      cm.session_id,
      cm.request_id,
      cm.token_info,
      cm.model_info,
      cm.gmt_create,
      cr.extra AS record_extra,
      cs.preferred_model_info
    FROM chat_message AS cm
    LEFT JOIN chat_record AS cr ON cr.request_id = cm.request_id
    LEFT JOIN chat_session AS cs ON cs.session_id = cm.session_id
    WHERE cm.role = 'assistant'
      AND cm.token_info IS NOT NULL
      AND trim(cm.token_info) NOT IN ('', '{}')
    ORDER BY cm.gmt_create, cm.rowid
    """

    private let configuredDatabaseURL: URL

    init(
        store: UsageStoring,
        databaseURL: URL = QoderUsageCollector.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.configuredDatabaseURL = databaseURL
        super.init(
            provider: .qoder,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var databaseURL: URL? { configuredDatabaseURL }

    override var usesRealDirectories: Bool {
        configuredDatabaseURL == QoderUsageCollector.defaultDatabaseURL()
    }

    override func readMessages() -> [SQLiteMessageRecord]? {
        guard let queue = SQLiteUsageCollectorBase.readOnlyQueue(at: configuredDatabaseURL) else {
            return nil
        }
        do {
            return try queue.read { db in
                let rows = try Row.fetchAll(db, sql: Self.qoderUsageSQL)
                var records: [SQLiteMessageRecord] = []
                // 请求级归属：完整有序快照里第一条消息拥有该 request 的会话计数。
                var requestOwners: [String: String] = [:]
                for row in rows {
                    let id = row["id"] as String?
                    let sessionID = row["session_id"] as String?
                    let requestID = row["request_id"] as String?
                    let rowID = row["row_id"] as Int64?
                    guard let key = QoderUsageProcessing.messageKey(
                        id: id,
                        sessionID: sessionID,
                        rowID: rowID
                    ), let totals = QoderUsageProcessing.normalizedTotals(
                        from: row["token_info"] as String?
                    ) else {
                        continue
                    }
                    let requestKey = QoderUsageProcessing.requestKey(
                        requestID: requestID,
                        sessionID: sessionID,
                        messageKey: key
                    )
                    if requestOwners[requestKey] == nil {
                        requestOwners[requestKey] = key
                    }
                    let gmtCreate = Self.numericDouble(row, "gmt_create")
                    records.append(SQLiteMessageRecord(
                        key: key,
                        timestampMs: SQLiteUsageCollectorBase.toEpochMilliseconds(gmtCreate),
                        totals: totals,
                        model: QoderUsageProcessing.modelName(
                            modelInfo: row["model_info"] as String?,
                            recordExtra: row["record_extra"] as String?,
                            preferredModelInfo: row["preferred_model_info"] as String?
                        ),
                        conversationCount: requestOwners[requestKey] == key ? 1 : 0
                    ))
                }
                return records
            }
        } catch {
            return nil // 锁/格式/权限：静默跳过本轮（错误处理表）
        }
    }

    /// gmt_create 可能存 INTEGER（毫秒）或 REAL：统一取 Double。
    private static func numericDouble(_ row: Row, _ column: String) -> Double? {
        if let int = row[column] as? Int64 {
            return Double(int)
        }
        return row[column] as? Double
    }

    override func processMessage(
        _ message: SQLiteMessageRecord,
        state: inout [String: String],
        fingerprintIndex: FingerprintIndex,
        scan: ScanContext
    ) -> Bool {
        guard let totals = message.totals,
              let timestampMs = message.timestampMs,
              let bucketStart = Self.bucketStart(fromMilliseconds: timestampMs) else {
            return false
        }
        let key = message.key
        var entry = Self.entry(for: key, state: state)

        // 未变化（totals/bucket/model/会话归属全同）→ 不动账本。
        let unchanged = entry.lastTotals == totals
            && entry.bucketStart == bucketStart.timeIntervalSince1970
            && entry.model == message.model
            && entry.conversationCount == message.conversationCount
        if unchanged {
            return false
        }

        // 减旧：从上次入桶的旧桶扣掉旧 totals 与会话。
        if let oldTotals = entry.lastTotals, let oldStart = entry.bucketStart {
            let oldModel = entry.model ?? message.model
            scan.aggregator.ingest(
                usage: Self.negated(oldTotals),
                conversationDelta: -entry.conversationCount,
                key: UsageBucketKey(provider: provider, model: oldModel, bucketStart: Date(timeIntervalSince1970: oldStart))
            )
        }
        // 加新：当前 totals 入当前桶。
        scan.aggregator.ingest(
            usage: totals,
            conversationDelta: message.conversationCount,
            key: UsageBucketKey(provider: provider, model: message.model, bucketStart: bucketStart)
        )
        entry.lastTotals = totals
        entry.bucketStart = bucketStart.timeIntervalSince1970
        entry.model = message.model
        entry.conversationCount = message.conversationCount
        state[key] = entry.encode()
        return true
    }
}