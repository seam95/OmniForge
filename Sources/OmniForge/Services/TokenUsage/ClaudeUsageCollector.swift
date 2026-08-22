import Combine
import Foundation

/// Claude Code 用量采集器（A 类本地 JSONL）。
///
/// 管线：目录监听信号（DispatchSource）+ 5 分钟定时兜底 → 串行队列扫描 →
/// JSONL 增量读（inode/offset 游标）→ 行解码（只取身份/用量字段）→
/// 消息级去重 key → 半小时桶聚合（累计快照 upsert）→ 通知管理器刷新快照。
///
/// 隐私红线（SPEC 2.6）：行解码只接触 `message.id/model/usage/type/uuid` 与
/// 内容块的 `type` 标记；prompt、消息正文与会话内容从不读取、绝不落盘。
final class ClaudeUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .claude

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（SPEC 5.6：5 分钟）。
    static let defaultScanInterval: TimeInterval = 5 * 60
    /// `~/.claude/projects`（支持 `CLAUDE_CONFIG_DIR` 环境变量覆盖）。
    static var defaultProjectsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override)
        } else {
            base = home.appendingPathComponent(".claude", isDirectory: true)
        }
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    /// 扫描计数（测试断言）。
    private(set) var scanCount = 0

    private let store: UsageStoring
    private let projectsDirectory: URL
    private let fileManager: FileManager
    private let scheduler: RepeatingScheduling
    private let watcher: DirectoryWatching
    private let scanInterval: TimeInterval
    private let queue = DispatchQueue(label: "omniForge.tokenUsage.claudeCollector", qos: .utility)
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 扫描信号合并：scanning = 已排队/正在执行的扫描；扫描中收到的信号置 rescanRequested。
    private var scanning = false
    private var rescanRequested = false
    private var backfillCompleted = false

    init(
        store: UsageStoring,
        projectsDirectory: URL = ClaudeUsageCollector.defaultProjectsDirectory,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = ClaudeUsageCollector.defaultScanInterval
    ) {
        self.store = store
        self.projectsDirectory = projectsDirectory
        self.fileManager = fileManager
        self.scheduler = scheduler
        self.watcher = watcher
        self.scanInterval = scanInterval
    }

    // MARK: - UsageCollecting

    func start() {
        guard !started else { return }
        started = true
        // 测试进程（xctest 环境）在生产接线 bootstrap 下不得扫描真实用户目录：
        // 会与真实应用争用同一 GRDB 库与游标文件（对齐 CodexUsageCollector 守卫）。
        guard !(isRunningUnitTests && usesRealUserDirectories) else { return }
        watcher.startWatching(url: projectsDirectory) { [weak self] in
            self?.triggerScan()
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

    /// 测试进程守卫（xctest 或 XCTestConfigurationFilePath 环境）。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）目录构造。
    private var usesRealUserDirectories: Bool {
        projectsDirectory == ClaudeUsageCollector.defaultProjectsDirectory
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

    private func performScan() {
        let files = Self.enumerateJSONLFiles(in: projectsDirectory, fileManager: fileManager)
        guard !files.isEmpty else { return }

        var cursors = store.loadCursors()
        var seen = store.loadSeenKeys()
        var newSeen = Set<String>()
        let aggregator = UsageAggregator { [store] key in
            store.loadBucket(key)
        }
        let decoder = JSONDecoder()

        for fileURL in files {
            guard let outcome = JSONLStreamReader.read(
                fileURL: fileURL,
                previous: cursors[fileURL.path],
                fileManager: fileManager
            ) else { continue }
            let isMainSession = !fileURL.pathComponents.contains("subagents")
            for line in outcome.lines {
                processLine(
                    line,
                    decoder: decoder,
                    aggregator: aggregator,
                    seen: &seen,
                    newSeen: &newSeen,
                    isMainSession: isMainSession
                )
            }
            cursors[fileURL.path] = outcome.cursor
            store.storeCursor(path: fileURL.path, cursor: outcome.cursor)
        }

        for state in aggregator.drainTouched() {
            store.upsertBucket(state)
        }
        guard !newSeen.isEmpty else { return }
        seen.formUnion(newSeen)
        // 只写新见 key（seen_at = 首次实际看见时间），避免每次扫描把全量 10 万级
        // key 的 seen_at 整体重写——否则截断退化、LRU 语义失真（参考 #09 评审 H4）。
        store.storeSeenKeys(newSeen, asOf: Date())
    }

    /// 单行处理：坏行跳过；token 行与 user 行共享已见集合去重（参考 02）。
    private func processLine(
        _ line: String,
        decoder: JSONDecoder,
        aggregator: UsageAggregator,
        seen: inout Set<String>,
        newSeen: inout Set<String>,
        isMainSession: Bool
    ) {
        guard line.contains("usage") || line.contains("user") else { return }
        guard let entry = try? decoder.decode(ClaudeTranscriptEntry.self, from: Data(line.utf8)) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }

        if entry.type == "assistant" {
            guard let usage = ClaudeUsageProcessing.tokenUsage(from: entry),
                  let bucketStart = ClaudeUsageProcessing.bucketStart(from: entry.timestamp) else {
                return
            }
            let key = ClaudeUsageProcessing.deduplicationKey(
                messageID: entry.message?.id,
                requestID: entry.requestId
            )
            if let key {
                guard !seen.contains(key), !newSeen.contains(key) else { return }
                newSeen.insert(key)
            }
            // 无 message.id 的行不给去重保护，照常计数（与 TokenTracker 一致）。
            aggregator.ingest(
                usage: usage,
                conversationDelta: 0,
                key: UsageBucketKey(
                    provider: provider,
                    model: ClaudeUsageProcessing.modelName(entry.message?.model ?? entry.model),
                    bucketStart: bucketStart
                )
            )
        } else if entry.type == "user", isMainSession {
            processUserLine(entry, aggregator: aggregator, seen: &seen, newSeen: &newSeen)
        }
    }

    /// 会话计数：仅主会话、带 text 块的 user 行；uuid 去重；桶键模型为 unknown（参考 02）。
    /// 无 uuid 的行照常计数但不可去重（与 TokenTracker 一致）。
    private func processUserLine(
        _ entry: ClaudeTranscriptEntry,
        aggregator: UsageAggregator,
        seen: inout Set<String>,
        newSeen: inout Set<String>
    ) {
        guard entry.message?.hasTextBlock == true else { return }
        guard let bucketStart = ClaudeUsageProcessing.bucketStart(from: entry.timestamp) else { return }
        let userKey = ClaudeUsageProcessing.userDeduplicationKey(uuid: entry.uuid)
        if let userKey {
            guard !seen.contains(userKey), !newSeen.contains(userKey) else { return }
            newSeen.insert(userKey)
        }
        aggregator.ingest(
            usage: .zero,
            conversationDelta: 1,
            key: UsageBucketKey(
                provider: provider,
                model: ClaudeUsageProcessing.defaultModel,
                bucketStart: bucketStart
            )
        )
    }

    // MARK: - 文件枚举

    /// 递归收集项目目录下全部 `.jsonl`（含 subagents/），按路径稳定排序。
    static func enumerateJSONLFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
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
