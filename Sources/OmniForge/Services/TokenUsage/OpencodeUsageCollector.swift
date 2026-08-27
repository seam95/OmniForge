import Combine
import Foundation
import GRDB

/// opencode-fork 的消息表采集器骨架（opencode / zcode 共用）。
///
/// 两代 schema 共用同一数据文件：v1 读 `message` 表（角色在 `data` JSON 的
/// `$.role`、模型为扁平 `modelID/providerID`）；v2（opencode2 重写存储层）读
/// `session_message` 表（角色在 `type` 列、模型嵌套 `$.model.{id,providerID}`）。
/// 代际按**行存在性**判定——`session_message` 表在纯 v1 库也存在但为空，按表
/// 存在性会把纯 v1 库判成 v2；混合库两表都读，同 key 消息由差分状态机天然
/// 去重（重放 totals 相同 → 增量为 0）。
///
/// SQL：全量读 assistant 消息（`data` JSON 列），`data.tokens` 为消息级累积值 →
/// 每消息「上次 totals 差分」求增量（PLAN §3.2）；`sessionID|messageID` 为消息 key；
/// 窄指纹跨会话去重 fork 复制（issue #426 语义）。
///
/// 隐私红线（SPEC 2.6）：DB 只读打开；只读 `data` 列的身份/模型/时间/用量字段，
/// 消息正文永不声明解析、绝不落盘。
class OpencodeSchemaCollectorBase: SQLiteUsageCollectorBase {
    /// DB 路径（子类指定）。
    var schemaDatabaseURL: URL? { nil }

    override var databaseURL: URL? { schemaDatabaseURL }

    /// 原生消息过滤（zcode 按 provider 黑名单剔除子代理）。
    func isNativeMessage(_ data: OpencodeMessageData) -> Bool { true }

    override func readMessages() -> [SQLiteMessageRecord]? {
        guard let dbURL = schemaDatabaseURL,
              let queue = SQLiteUsageCollectorBase.readOnlyQueue(at: dbURL) else {
            return nil
        }
        do {
            return try queue.read { db in
                // 代际探测：session_message 有行 → v2（表存在但为空不算）。
                let hasV2Rows = (try? Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS (SELECT 1 FROM session_message)"
                )) ?? nil
                var rows: [Row] = []
                if hasV2Rows == true {
                    rows += try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, session_id, data FROM session_message
                        WHERE type = 'assistant'
                        ORDER BY time_created ASC
                        """
                    )
                }
                // 纯 v2 库的 message 表已不存在 → 该查询抛错即跳过 v1 段。
                if let v1Rows = try? Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, session_id, data FROM message
                    WHERE json_extract(data, '$.role') = 'assistant'
                    ORDER BY time_created ASC
                    """
                ) {
                    rows += v1Rows
                }
                var records: [SQLiteMessageRecord] = []
                for row in rows {
                    guard let dataString = row["data"] as String?,
                          let data = try? JSONDecoder().decode(OpencodeMessageData.self, from: Data(dataString.utf8)),
                          isNativeMessage(data) else {
                        continue
                    }
                    let rowID = row["id"] as String?
                    let rowSession = row["session_id"] as String?
                    guard let key = OpencodeUsageProcessing.messageKey(
                        id: rowID ?? data.id,
                        sessionID: rowSession ?? data.sessionID
                    ), let totals = OpencodeUsageProcessing.normalizedTotals(from: data.tokens) else {
                        continue
                    }
                    records.append(SQLiteMessageRecord(
                        key: key,
                        sessionKey: rowSession ?? data.sessionID,
                        timestampMs: OpencodeUsageProcessing.timestampMs(data),
                        totals: totals,
                        model: OpencodeUsageProcessing.modelName(data),
                        fingerprint: OpencodeUsageProcessing.fingerprint(
                            source: provider.rawValue,
                            data: data,
                            totals: totals
                        )
                    ))
                }
                return records
            }
        } catch {
            return nil // 锁/格式/权限：静默跳过本轮（错误处理表）
        }
    }

    override func processMessage(
        _ message: SQLiteMessageRecord,
        state: inout [String: String],
        fingerprintIndex: FingerprintIndex,
        scan: ScanContext
    ) -> Bool {
        guard let totals = message.totals else { return false }
        let key = message.key
        var entry = Self.entry(for: key, state: state)

        // fork 复制：同指纹已被**其他会话**的已计数消息认领 → 跳过并记 tombstone。
        if let fingerprint = message.fingerprint, !fingerprint.isEmpty,
           let owner = fingerprintIndex.owner(for: fingerprint),
           owner != key,
           let ownerSession = Self.sessionKey(from: owner),
           let thisSession = message.sessionKey,
           ownerSession != thisSession {
            entry.dedupedForkCopy = true
            entry.lastTotals = totals
            entry.fingerprint = fingerprint
            state[key] = entry.encode()
            return true
        }

        let delta = Self.diffTotals(
            current: totals,
            previous: entry.dedupedForkCopy ? nil : entry.lastTotals
        )
        if let delta, !Self.isZeroUsage(delta),
           let timestampMs = message.timestampMs,
           let bucketStart = Self.bucketStart(fromMilliseconds: timestampMs) {
            scan.aggregator.ingest(
                usage: delta,
                conversationDelta: 1,
                key: UsageBucketKey(provider: provider, model: message.model, bucketStart: bucketStart)
            )
        }
        entry.lastTotals = totals
        entry.fingerprint = message.fingerprint
        entry.dedupedForkCopy = false
        state[key] = entry.encode()
        if let fingerprint = message.fingerprint, !fingerprint.isEmpty {
            fingerprintIndex.claim(fingerprint, key: key)
        }
        return true
    }
}

/// opencode 用量采集器（B 类 SQLite）。
///
/// 数据源：`~/.local/share/opencode/opencode.db`（`$OPENCODE_HOME` 覆盖）。
/// 说明：`storage/message/` JSONL 旧通道（opencode < v1.2）本期不接，仅 SQLite 通道
/// （现代 opencode 全量走 DB；见 SPEC §4.2 B 类）。
final class OpencodeUsageCollector: OpencodeSchemaCollectorBase {
    static func defaultDatabaseURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["OPENCODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("opencode.db")
        }
        return URL(fileURLWithPath: homePath + "/.local/share/opencode/opencode.db")
    }

    private let configuredDatabaseURL: URL

    init(
        store: UsageStoring,
        databaseURL: URL = OpencodeUsageCollector.defaultDatabaseURL(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.configuredDatabaseURL = databaseURL
        super.init(
            provider: .opencode,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var schemaDatabaseURL: URL? { configuredDatabaseURL }

    override var usesRealDirectories: Bool {
        configuredDatabaseURL == OpencodeUsageCollector.defaultDatabaseURL()
    }
}