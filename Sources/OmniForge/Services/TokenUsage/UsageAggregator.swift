import Foundation

/// 半小时桶内存聚合器 — 挂在持久化累计状态上的纯逻辑。
///
/// 幂等语义（参考 02 queue.jsonl 约定）：
/// - 每次写库写入该 key 的**累计快照**（非增量），重复写同一值结果不变；
/// - 重新解析同一批增量时，从持久化累计 seed 后累加得到相同累计值。
final class UsageAggregator {
    /// 从持久化读取既有累计（桶首次被触碰时调用一次）。
    private let seedLoader: (UsageBucketKey) -> UsageBucketState?
    private var buckets: [UsageBucketKey: UsageBucketState] = [:]
    /// 本次被触碰的桶（只写这些，参考 02 touchedBuckets）。
    private(set) var touched = Set<UsageBucketKey>()

    init(seedLoader: @escaping (UsageBucketKey) -> UsageBucketState? = { _ in nil }) {
        self.seedLoader = seedLoader
    }

    /// 累加一条行级增量。
    func ingest(usage delta: TokenUsage, conversationDelta: Int, key: UsageBucketKey) {
        let current = buckets[key] ?? seedLoader(key) ?? .empty(key)
        buckets[key] = current.adding(usage: delta, conversations: conversationDelta)
        touched.insert(key)
    }

    /// 取出本次被触碰桶的累计快照，并清空 touched（写完库后可安全复用聚合器）。
    func drainTouched() -> [UsageBucketState] {
        let states = touched.compactMap { buckets[$0] }
        touched.removeAll()
        return states
    }
}
