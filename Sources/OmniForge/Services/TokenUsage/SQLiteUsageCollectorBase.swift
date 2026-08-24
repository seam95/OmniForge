import Foundation
import GRDB

/// B 类（本地 SQLite）用量采集器骨架 — 只读打开 + 全量读 + 每消息状态差分 + 聚合写桶。
///
/// 复用 `JSONLUsageCollectorBase` 的调度骨架（目录监听/定时兜底/信号合并/回填通知），
/// 把 provider 的 SQLite 文件当作单个「文件」：每次扫描全量重读，靠**消息级状态账本**
/// （`UsageStoring.providerMessageState`，按 provider 隔离）做差分幂等，不依赖
/// 字节游标。多供应商接入（2026-08-24，期 3；PLAN §3.1）。
///
/// 子类注入点：
/// - `databaseURL`：DB 路径（nil = 未配置 → 整轮跳过）；
/// - `readMessages()`：只读打开 + SQL + 行映射（nil = 打开失败，跳过本轮）；
/// - `processMessage(_:state:scan:)`：单条消息差分逻辑（返回是否变更状态账本）。
///
/// 隐私红线（SPEC 2.6）：只读 token 数字、时间戳、模型名与身份字段；消息正文与
/// 文件内容永不落盘（provider DB 只读打开，绝不写入）。
class SQLiteUsageCollectorBase: JSONLUsageCollectorBase {
    // MARK: - 消息快照

    /// B 类全量读的通用消息快照（子类 SQL 映射产出）。
    struct SQLiteMessageRecord {
        /// 消息级唯一键（如 `sessionID|messageID`）。
        var key: String
        /// 会话段（fork 复制判定的跨会话前缀；nil = 不做跨会话去重）。
        var sessionKey: String?
        /// epoch 毫秒。
        var timestampMs: Double?
        /// 当前累计六列（nil = 该行无用量，跳过）。
        var totals: TokenUsage?
        var model: String
        /// 幂等指纹（fork 复制去重；nil = 不支持）。
        var fingerprint: String?
        /// qoder 请求级会话归属：本行应为 request 的第几条消息（0/1）。
        var conversationCount: Int

        init(
            key: String,
            sessionKey: String? = nil,
            timestampMs: Double?,
            totals: TokenUsage?,
            model: String,
            fingerprint: String? = nil,
            conversationCount: Int = 1
        ) {
            self.key = key
            self.sessionKey = sessionKey
            self.timestampMs = timestampMs
            self.totals = totals
            self.model = model
            self.fingerprint = fingerprint
            self.conversationCount = conversationCount
        }
    }

    /// 消息级状态账本条目（JSON 载荷编解码）。
    struct MessageState: Codable, Equatable {
        var lastTotals: TokenUsage?
        var fingerprint: String?
        var dedupedForkCopy: Bool = false
        /// qoder「减旧加新」需要：上次入桶的桶起点与模型。
        var bucketStart: Double?
        var model: String?
        var conversationCount: Int = 0

        static func decode(_ payload: String?) -> MessageState? {
            guard let payload, let data = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(MessageState.self, from: data)
        }

        func encode() -> String {
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: - 子类注入点

    /// DB 路径；nil = 未配置（跳过本轮）。
    var databaseURL: URL? { nil }

    /// 全量读消息；nil = 打开/查询失败（跳过本轮，不写状态）。
    func readMessages() -> [SQLiteMessageRecord]? { nil }

    /// 处理单条消息；返回 true 表示状态账本有变更（需要持久化）。
    /// `fingerprintIndex` 为本次扫描的指纹 → messageKey 索引（fork 复制去重用，
    /// 扫描中可认领新指纹）。
    func processMessage(
        _ message: SQLiteMessageRecord,
        state: inout [String: String],
        fingerprintIndex: FingerprintIndex,
        scan: ScanContext
    ) -> Bool {
        false
    }

    // MARK: - 文件化（复用 JSONL 基类调度）

    override func enumerateFiles() -> [URL] {
        guard let dbURL = databaseURL, fileManager.fileExists(atPath: dbURL.path) else { return [] }
        return [dbURL.standardizedFileURL]
    }

    /// 监听 DB 所在目录（DB 文件被改写时触发扫描；目录不存在时 open 静默失败）。
    override var primaryWatchDirectory: URL? {
        databaseURL?.deletingLastPathComponent()
    }

    override func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        guard let messages = readMessages() else { return consumedCursor(file) }
        var state = store.loadProviderMessageState(provider)
        let fingerprintIndex = FingerprintIndex(state)
        var changed = false
        for message in messages {
            if processMessage(message, state: &state, fingerprintIndex: fingerprintIndex, scan: scan) {
                changed = true
            }
        }
        if changed {
            store.storeProviderMessageState(provider, entries: state)
        }
        return consumedCursor(file)
    }

    private func consumedCursor(_ file: URL) -> JSONLCursor? {
        let attrs = try? fileManager.attributesOfItem(atPath: file.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return JSONLCursor(inode: inode, offset: size)
    }

    // MARK: - 只读打开（GRDB）

    /// 只读打开 SQLite；失败（不存在/锁/格式）→ nil（静默跳过）。
    static func readOnlyQueue(at url: URL) -> DatabaseQueue? {
        var configuration = Configuration()
        configuration.readonly = true
        return try? DatabaseQueue(path: url.path, configuration: configuration)
    }

    // MARK: - 共享差分工具

    /// opencode 语义差分：`current - previous` 逐列 clamp；total 回退 → 整行取 current；
    /// 相同 → nil。
    static func diffTotals(current: TokenUsage, previous: TokenUsage?) -> TokenUsage? {
        guard let previous else { return current }
        if current == previous { return nil }
        if current.totalTokens < previous.totalTokens { return current }
        return TokenUsage(
            inputTokens: max(0, current.inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, current.cachedInputTokens - previous.cachedInputTokens),
            cacheCreationInputTokens: max(0, current.cacheCreationInputTokens - previous.cacheCreationInputTokens),
            outputTokens: max(0, current.outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, current.reasoningOutputTokens - previous.reasoningOutputTokens),
            totalTokens: max(0, current.totalTokens - previous.totalTokens)
        )
    }

    /// 全零判定（跳过零增量）。
    static func isZeroUsage(_ usage: TokenUsage) -> Bool {
        usage.totalTokens <= 0
    }

    /// 逐列取负（qoder「减旧加新」的减旧步）。
    static func negated(_ usage: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: -usage.inputTokens,
            cachedInputTokens: -usage.cachedInputTokens,
            cacheCreationInputTokens: -usage.cacheCreationInputTokens,
            outputTokens: -usage.outputTokens,
            reasoningOutputTokens: -usage.reasoningOutputTokens,
            totalTokens: -usage.totalTokens
        )
    }

    /// 时间戳秒/毫秒自适应 → epoch 毫秒；`< 1e10` 视为秒。
    static func toEpochMilliseconds(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }

    /// 毫秒时间戳 → UTC 半小时桶起点。
    static func bucketStart(fromMilliseconds ms: Double?) -> Date? {
        guard let ms, ms > 0, ms.isFinite else { return nil }
        let seconds = Int(ms / 1000)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }
}

// MARK: - 状态账本便捷访问

extension SQLiteUsageCollectorBase {
    /// 读取/创建消息状态条目。
    static func entry(for key: String, state: [String: String]) -> MessageState {
        MessageState.decode(state[key]) ?? MessageState()
    }

    /// messageKey 的会话段（`sessionID|messageID` 的前缀）。
    static func sessionKey(from messageKey: String) -> String? {
        guard let idx = messageKey.firstIndex(of: "|") else { return nil }
        return String(messageKey[..<idx])
    }
}

// MARK: - fork 复制指纹索引（单次扫描共享）

/// 指纹 → messageKey 认领表：从既有状态账本构建（跳过 tombstone），扫描中
/// 先见者认领（fork 复制先例在后，按 time 序原会话在前）。
final class FingerprintIndex {
    private var owners: [String: String] = [:]

    init(_ state: [String: String]) {
        for (key, payload) in state {
            guard let entry = SQLiteUsageCollectorBase.MessageState.decode(payload),
                  entry.dedupedForkCopy != true,
                  let fingerprint = entry.fingerprint, !fingerprint.isEmpty else {
                continue
            }
            if owners[fingerprint] == nil {
                owners[fingerprint] = key
            }
        }
    }

    /// 该指纹的既有认领者（无 → nil）。
    func owner(for fingerprint: String) -> String? {
        owners[fingerprint]
    }

    /// 认领指纹（首次认领生效；tombstone 不复认领）。
    func claim(_ fingerprint: String, key: String) {
        if owners[fingerprint] == nil {
            owners[fingerprint] = key
        }
    }
}