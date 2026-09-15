import Foundation

/// 聚合桶写入策略（参考 02 queue.jsonl 约定）。
enum UsageStorePolicy {
    /// 已见 key 容量上限，超出做 LRU 淘汰（参考 02：10 万条封顶）。
    static let maxSeenKeys = 100_000
}

/// 用量存储错误（原子提交路径）。
enum UsageStoreError: Error, LocalizedError {
    /// 数据库初始化失败降级后所有写路径的统一失败。
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "用量数据库不可用"
        }
    }
}

/// 用量存储边界 — GRDB 实现 + 测试替身（协议在 Services 层）。
///
/// 隐私红线（SPEC 2.6）：只存 token 数字与时间戳；上游解析永不写入
/// prompt/消息正文/会话内容。
protocol UsageStoring: AnyObject {
    // 半小时桶：主键 (provider, model, bucket_start)，last-writer-wins。
    func upsertBucket(_ state: UsageBucketState)
    func loadBucket(_ key: UsageBucketKey) -> UsageBucketState?
    func loadBuckets(
        from start: Date,
        to end: Date,
        providers: Set<TokenUsageProvider>?
    ) -> [UsageBucketState]

    // 聚合查询（仪表盘重设计）：SQL 侧聚合，避免把整年半小时桶物化进内存。
    /// 按本地日 × provider 聚合（`GROUP BY day, provider`），用于汇总卡 / 热力图 / 趋势。
    func loadDailyAggregates(
        from start: Date,
        to end: Date,
        providers: Set<TokenUsageProvider>?
    ) -> [UsageDayProviderAggregate]
    /// 按模型聚合（`GROUP BY model`，按总量降序）。
    func loadModelAggregates(
        from start: Date,
        to end: Date,
        providers: Set<TokenUsageProvider>?
    ) -> [UsageModelAggregate]

    // 已见消息 id 集合（跨 sync 持久化；容量上限 LRU 截断）。
    func loadSeenKeys() -> Set<String>
    func storeSeenKeys(_ keys: Set<String>, asOf date: Date)

    // 文件游标 {inode, offset}。
    func loadCursors() -> [String: JSONLCursor]
    func storeCursor(path: String, cursor: JSONLCursor)
    func removeCursor(path: String)
    func clearCursors()

    // 提供者消息级状态账本（SQLite 差分采集：lastTotals/指纹/会话归属等；按 provider 隔离）。
    func loadProviderMessageState(_ provider: TokenUsageProvider) -> [String: String]
    func storeProviderMessageState(_ provider: TokenUsageProvider, entries: [String: String])

    /// 一轮扫描的原子提交（审查 R14）：桶贡献、文件游标、新见 key、消息状态变更
    /// 在同一事务内读改写落库。任何一部分失败时整体不生效，调用方保留旧进度
    /// （下轮从旧游标重读重算，配合去重/差分天然幂等）。
    /// GRDB 实现为真事务；默认实现按序组合旧方法（内存替身语义等价）。
    func commitScan(_ commit: ScanCommit) throws
}

/// 单轮扫描的原子提交载荷（审查 R14：游标推进必须后于桶写入成功）。
struct ScanCommit {
    var buckets: [UsageBucketState] = []
    /// 本次推进的文件游标（path → cursor）。
    var cursors: [String: JSONLCursor] = [:]
    /// 本次新见的去重 key。
    var newSeenKeys: Set<String> = []
    var seenAt: Date = Date()
    /// 消息级状态账本变更（provider → 变更条目；只含 dirty 条目）。
    var messageStateUpdates: [(provider: TokenUsageProvider, entries: [String: String])] = []
}

extension UsageStoring {
    /// 默认组合实现：内存替身或未实现原子事务的存储按序应用（无中断语义下等价）。
    func commitScan(_ commit: ScanCommit) throws {
        for bucket in commit.buckets {
            upsertBucket(bucket)
        }
        for (path, cursor) in commit.cursors {
            storeCursor(path: path, cursor: cursor)
        }
        if !commit.newSeenKeys.isEmpty {
            storeSeenKeys(commit.newSeenKeys, asOf: commit.seenAt)
        }
        for (provider, entries) in commit.messageStateUpdates {
            storeProviderMessageState(provider, entries: entries)
        }
    }
}
