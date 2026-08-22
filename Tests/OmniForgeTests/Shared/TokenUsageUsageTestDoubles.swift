import Foundation
import XCTest
@testable import OmniForge

/// 测试辅助：用量存储/采集器/目录监听的替身；仅安全测试用。
/// 真实等价物：GRDBUsageStore / ClaudeUsageCollector / DispatchSourceDirectoryWatcher。

/// 内存版用量存储 — 镜像 GRDB 语义（主键 upsert last-writer-wins / seen 集合 / 游标字典）。
final class FakeUsageStore: UsageStoring {
    var bucketsByKey: [UsageBucketKey: UsageBucketState] = [:]
    var seenKeys: Set<String> = []
    var cursors: [String: JSONLCursor] = [:]
    var maxSeenKeys = 100_000
    /// 非零时每次 upsert 挂起（并发/合并测试用）。
    var upsertDelay: TimeInterval = 0
    private(set) var upsertCount = 0

    func upsertBucket(_ state: UsageBucketState) {
        if upsertDelay > 0 { Thread.sleep(forTimeInterval: upsertDelay) }
        upsertCount += 1
        bucketsByKey[state.key] = state
    }

    func loadBucket(_ key: UsageBucketKey) -> UsageBucketState? {
        bucketsByKey[key]
    }

    func loadBuckets(from start: Date, to end: Date, providers: Set<TokenUsageProvider>?) -> [UsageBucketState] {
        bucketsByKey.values.filter { state in
            state.key.bucketStart >= start && state.key.bucketStart < end
        }.filter { state in
            providers?.contains(state.key.provider) ?? true
        }
    }

    func loadSeenKeys() -> Set<String> {
        seenKeys
    }

    func storeSeenKeys(_ keys: Set<String>, asOf date: Date) {
        // 镜像 GRDB 语义：按 key 逐条 upsert（合并），不是整体替换。
        seenKeys.formUnion(keys)
        if seenKeys.count > maxSeenKeys {
            let excess = seenKeys.count - maxSeenKeys
            let dropped = seenKeys.sorted().prefix(excess)
            for key in dropped { seenKeys.remove(key) }
        }
    }

    func loadCursors() -> [String: JSONLCursor] {
        cursors
    }

    func storeCursor(path: String, cursor: JSONLCursor) {
        cursors[path] = cursor
    }

    func removeCursor(path: String) {
        cursors.removeValue(forKey: path)
    }

    func clearCursors() {
        cursors.removeAll()
    }

    /// 窗口内会话数（断言辅助）。
    func totalTokens(in window: (start: Date, end: Date)? = nil) -> Int {
        bucketsByKey.values
            .filter { state in
                guard let window else { return true }
                return state.key.bucketStart >= window.start && state.key.bucketStart < window.end
            }
            .reduce(0) { $0 + $1.usage.totalTokens }
    }

    func conversations(in window: (start: Date, end: Date)? = nil) -> Int {
        bucketsByKey.values
            .filter { state in
                guard let window else { return true }
                return state.key.bucketStart >= window.start && state.key.bucketStart < window.end
            }
            .reduce(0) { $0 + $1.conversationCount }
    }
}

/// 测试用用量采集器替身 — 记录启停并可手动触发回馈。
final class FakeUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    init(provider: TokenUsageProvider) {
        self.provider = provider
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func simulateUsageChanged() {
        onUsageDidChange?(provider)
    }

    func simulateBackfill(_ value: Bool) {
        onBackfillStateChange?(value)
    }
}

/// 测试用目录监听替身 — 记录监视目录并可手动触发变更信号。
final class FakeDirectoryWatcher: DirectoryWatching {
    private(set) var watchedURL: URL?
    private(set) var isWatching = false
    private var onChange: (() -> Void)?

    func startWatching(url: URL, onChange: @escaping () -> Void) {
        watchedURL = url
        isWatching = true
        self.onChange = onChange
    }

    func stopWatching() {
        isWatching = false
        watchedURL = nil
        onChange = nil
    }

    func simulateChange() {
        onChange?()
    }
}
