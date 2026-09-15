import Combine
import Foundation

/// A 类（本地 JSONL）用量采集器骨架 — 目录监听 + 串行队列 + 信号合并 + 增量游标 + 聚合写桶。
///
/// 从 `ClaudeUsageCollector` 抽取公共骨架（2026-08-24 多供应商接入，期 1），供
/// Claude / Kimi / grok / dsh / codebuddy / workbuddy 等本地 JSONL 采集器复用。
///
/// 子类注入点（PLAN §1.2）：
/// - `enumerateFiles()`：目录发现规则（返回本次要扫描的文件 URL）；
/// - `processLine(_:decoder:state:scan:)`：行解析纯逻辑 → 通过 `scan` 写增量/去重；
/// - `newFileState(file:cursor:)`：每文件可变状态（如 Kimi 的模型归属）；
/// - `primaryWatchDirectory`：监听根目录（nil 不监听，靠定时兜底）；
/// - `usesRealDirectories`：测试进程守护（子类判断是否以真实用户目录构造）。
///
/// 隐私红线（SPEC 2.6）：行解析只接触身份/用量字段；prompt、消息正文与会话内容
/// 从不读取、绝不落盘。
class JSONLUsageCollectorBase: UsageCollecting {
    let provider: TokenUsageProvider

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（SPEC 5.6：5 分钟）。
    static let defaultScanInterval: TimeInterval = 5 * 60

    /// 扫描计数（测试断言）。
    private(set) var scanCount = 0

    /// 子类枚举/解析所需（同一模块内部可见）。
    let store: UsageStoring
    let fileManager: FileManager
    private let scanInterval: TimeInterval
    private let scheduler: RepeatingScheduling
    private let watcher: DirectoryWatching
    private let queue: DispatchQueue
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 扫描信号合并：scanning = 已排队/正在执行的扫描；扫描中收到的信号置 rescanRequested。
    private var scanning = false
    private var rescanRequested = false
    private var backfillCompleted = false

    // MARK: - 子类注入点

    /// 是否以默认（真实用户）目录构造（测试进程守护，见 `start()`）。
    var usesRealDirectories: Bool { false }

    /// 目录监听根；nil 表示不监听（仅定时兜底）。
    var primaryWatchDirectory: URL? { nil }

    /// 本次要扫描的文件 URL（目录发现规则）。
    func enumerateFiles() -> [URL] { [] }

    /// 每文件扫描状态；默认承载模型归属（Kimi 语义）与 sessionId（dsh/grok 去重）。
    struct FileScanState {
        var model: String?
        var sessionId: String?
        init(model: String? = nil, sessionId: String? = nil) {
            self.model = model
            self.sessionId = sessionId
        }
    }

    /// 新文件/归零重读时创建文件状态。
    func newFileState(file: URL, cursor: JSONLCursor?) -> FileScanState {
        FileScanState(model: cursor?.model)
    }

    /// 单行处理：子类实现解析 → 通过 `scan` 写增量/去重 key/会话计数。
    func processLine(
        _ line: String,
        decoder: JSONDecoder,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
    ) {
        // 子类必须实现。
    }

    /// 处理单个文件；默认走 JSONL 增量**流式**读（分块逐行 `processLine`，审查 R17）。
    /// 子类可覆盖以支持整文件读取（如 grok 的 signals.json 兜底）。
    /// 返回新游标；nil = 跳过不写游标（文件缺失/不可读/超长行，进度可重试）。
    func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        var state = newFileState(file: file, cursor: previous)
        guard let cursor = JSONLStreamReader.forEachLine(
            fileURL: file,
            previous: previous,
            fileManager: fileManager,
            consume: { line in
                processLine(line, decoder: decoder, file: file, state: &state, scan: scan)
            }
        ) else { return nil }
        return JSONLCursor(
            inode: cursor.inode,
            offset: cursor.offset,
            model: state.model
        )
    }

    // MARK: - 初始化

    init(
        provider: TokenUsageProvider,
        store: UsageStoring,
        scanInterval: TimeInterval,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher()
    ) {
        self.provider = provider
        self.store = store
        self.scanInterval = scanInterval
        self.fileManager = fileManager
        self.scheduler = scheduler
        self.watcher = watcher
        self.queue = DispatchQueue(
            label: "omniForge.tokenUsage.\(provider.rawValue)Collector",
            qos: .utility
        )
    }

    // MARK: - UsageCollecting

    /// 测试进程守卫（xctest 或 XCTestConfigurationFilePath 环境）。
    fileprivate var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    func start() {
        guard !started else { return }
        started = true
        // 测试进程（xctest 环境）在生产接线 bootstrap 下不得扫描真实用户目录：
        // 会与真实应用争用同一 GRDB 库与游标文件（对齐 Codex/Claude 采集器守卫）。
        guard !(isRunningUnitTests && usesRealDirectories) else { return }
        if let watchURL = primaryWatchDirectory {
            watcher.startWatching(url: watchURL) { [weak self] in
                self?.triggerScan()
            }
        }
        timer = scheduler.schedule(every: scanInterval) { [weak self] in
            self?.triggerScan()
        }
        triggerScan()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stopWatching()
        timer?.cancel()
        timer = nil
    }

    /// 线程安全：等待串行队列排空（测试用）。
    func waitForIdle() {
        queue.sync {}
    }

    // MARK: - 扫描调度（信号与解析分离 + 信号合并）

    /// 触发一次扫描：合并机制锁保护——扫描中到达的多个信号只追加一次「重新扫描」。
    private func triggerScan() {
        triggerLock.lock()
        if scanning {
            rescanRequested = true
            triggerLock.unlock()
            return
        }
        scanning = true
        triggerLock.unlock()
        queue.async { [weak self] in
            self?.performScanCycle()
        }
    }

    /// 串行队列上执行完整一轮扫描（含回填状态与回调通知）。
    private func performScanCycle() {
        scanCount += 1
        let isBackfill = !backfillCompleted
        if isBackfill {
            notifyBackfill(true)
        }

        performScan()

        if isBackfill {
            backfillCompleted = true
            notifyBackfill(false)
        }
        notifyUsageChanged()

        // 锁内直接续跑 rescan：避免 scanning=false 到再次触发之间的空隙产生双触发竞态。
        triggerLock.lock()
        scanning = false
        let again = rescanRequested && started
        rescanRequested = false
        if again {
            scanning = true
        }
        triggerLock.unlock()
        if again {
            queue.async { [weak self] in
                self?.performScanCycle()
            }
        }
    }

    // MARK: - 扫描

    /// 全量一轮：增量游标读 → 行解析 → 聚合 → **原子提交**（桶/游标/新见 key/
    /// 消息状态同一事务，审查 R14）。提交失败不推进任何进度：下轮从旧游标
    /// 重读重算，配合去重与差分幂等，不产生漏计或重复计数。
    fileprivate func performScan() {
        let files = enumerateFiles()
        guard !files.isEmpty else { return }

        var cursors = store.loadCursors()
        let scan = ScanContext(provider: provider, aggregator: UsageAggregator { [store] key in
            store.loadBucket(key)
        }, seen: store.loadSeenKeys())
        let decoder = JSONDecoder()

        var commit = ScanCommit()
        for fileURL in files {
            let previous = cursors[fileURL.path]
            guard let cursor = visit(file: fileURL, previous: previous, decoder: decoder, scan: scan) else {
                continue
            }
            cursors[fileURL.path] = cursor
            commit.cursors[fileURL.path] = cursor
        }

        commit.buckets = scan.aggregator.drainTouched()
        commit.newSeenKeys = scan.drainNewSeen()
        // seen_at = 首次实际看见时间；只写新见 key，避免全量重写
        // （截断退化、LRU 语义失真；参考 #09 评审 H4）。
        commit.seenAt = Date()
        commit.messageStateUpdates = scan.drainMessageStateUpdates()

        do {
            try store.commitScan(commit)
        } catch {
            // 提交失败：内存进度随本轮丢弃（cursors 局部变量），下轮重扫重算。
            print("[UsageCollector] commitScan failed, will rescan from last committed cursors: \(error)")
        }
    }

    // MARK: - 文件枚举

    /// 递归收集目录下满足谓词的文件，按路径稳定排序（统一先解析符号链接前缀）。
    static func enumerateFiles(
        in directory: URL,
        fileManager: FileManager,
        where predicate: (URL) -> Bool
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard predicate(url) else { continue }
            // 统一解析符号链接前缀（/var → /private/var），保证游标 key 稳定。
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - 通知

    private func notifyUsageChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onUsageDidChange?(self.provider)
        }
    }

    private func notifyBackfill(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onBackfillStateChange?(value)
        }
    }
}

// MARK: - 单次扫描上下文

extension JSONLUsageCollectorBase {
    /// 单次扫描的共享上下文：聚合器 + 已见/新见去重集合 + 会话计数。
    ///
    /// `markSeen` 在 `seen`（既有）+ `newSeen`（本次）双集合去重；扫描结束由
    /// 基类把 `newSeen` 追加写库。
    final class ScanContext {
        let provider: TokenUsageProvider
        let aggregator: UsageAggregator
        private let seen: Set<String>
        private(set) var newSeen: Set<String> = []

        init(provider: TokenUsageProvider, aggregator: UsageAggregator, seen: Set<String>) {
            self.provider = provider
            self.aggregator = aggregator
            self.seen = seen
        }

        /// 尝试登记去重 key；返回 true 表示首次见到（调用方应计数）。
        func markSeen(_ key: String) -> Bool {
            guard !seen.contains(key), !newSeen.contains(key) else { return false }
            newSeen.insert(key)
            return true
        }

        /// 是否已见过该 key（本次或既有；用于跨来源互斥标记查询，不写入）。
        func isSeen(_ key: String) -> Bool {
            seen.contains(key) || newSeen.contains(key)
        }

        /// 取出本次新见 key 并清空（基类扫描末尾写库）。
        func drainNewSeen() -> Set<String> {
            let drained = newSeen
            newSeen.removeAll()
            return drained
        }

        /// 消息级状态账本的 dirty 变更（SQLite 差分采集暂存；随原子提交落库）。
        private(set) var messageStateUpdates: [(provider: TokenUsageProvider, entries: [String: String])] = []

        /// 暂存一 provider 的变更条目（同 provider 多次暂存会合并去重，后写覆盖）。
        func stageMessageState(provider: TokenUsageProvider, entries: [String: String]) {
            if let index = messageStateUpdates.firstIndex(where: { $0.provider == provider }) {
                var merged = messageStateUpdates[index].entries
                for (key, payload) in entries {
                    merged[key] = payload
                }
                messageStateUpdates[index].entries = merged
            } else {
                messageStateUpdates.append((provider, entries))
            }
        }

        /// 取出并清空消息状态变更（基类扫描末尾统一提交）。
        func drainMessageStateUpdates() -> [(provider: TokenUsageProvider, entries: [String: String])] {
            let drained = messageStateUpdates
            messageStateUpdates = []
            return drained
        }

        /// 便捷入口：去重通过 + 无 key 时直接入桶。
        func ingest(
            dedupKey: String?,
            usage delta: TokenUsage,
            conversationDelta: Int = 0,
            model: String,
            bucketStart: Date?
        ) {
            guard let bucketStart else { return }
            if let dedupKey {
                guard markSeen(dedupKey) else { return }
            }
            aggregator.ingest(
                usage: delta,
                conversationDelta: conversationDelta,
                key: UsageBucketKey(
                    provider: provider,
                    model: model,
                    bucketStart: bucketStart
                )
            )
        }
    }
}