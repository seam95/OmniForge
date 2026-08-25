import Foundation

/// 聚合桶写入策略（参考 02 queue.jsonl 约定）。
enum UsageStorePolicy {
    /// 已见 key 容量上限，超出做 LRU 淘汰（参考 02：10 万条封顶）。
    static let maxSeenKeys = 100_000
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
    /// 按模型聚合（`GROUP BY model`，按总量降序），用于模型 Top 列表。
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
}
