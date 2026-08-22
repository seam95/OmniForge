import Combine
import Foundation

/// Gemini 用量采集器（整文件 JSON 会话快照，非 JSONL — 参考 01/08）。
///
/// Gemini CLI 把每次 sync 后的**整份**会话快照重写为 `~/.gemini/tmp/<项目>/chats/session-*.json`
/// （消息级 token 为**累计**值）。因此本采集器：
/// - 以 `{inode, size}` 为文件游标：size 变化（含截断重写）→ 整文件重扫；
/// - 消息级**相邻差量**（增量，参考 TokenTracker parseGeminiIncremental）；
/// - 以消息 id 去重（genmi:<id>）保证重扫不重复计费（快照语义下不可做字节增量）；
/// - 无时间戳消息：推进差量基线但不入桶、不写去重 key（之后补时间戳仍可计数）；
/// - 无 id 消息：不可去重 → 保守跳过（避免重扫重复计费）；坏 JSON/无关文件跳过硬抗。
///
/// 隐私红线（SPEC 2.6）：解码只声明 `id/type/timestamp/model/tokens`；
/// content.text 等正文由 JSONDecoder 未声明键直接丢弃，绝不解析、绝不落盘。
final class GeminiUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .gemini

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（SPEC 5.6：5 分钟；目录监听只覆盖子目录直接变化）。
    static let defaultScanInterval: TimeInterval = 5 * 60

    /// `~/.gemini/tmp`（支持 `GEMINI_HOME` 环境变量覆盖，参考 01/08）。
    static func defaultTmpDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let override = environment["GEMINI_HOME"], !override.isEmpty {
            base = URL(fileURLWithPath: override)
        } else {
            base = URL(fileURLWithPath: homePath + "/.gemini")
        }
        return base.appendingPathComponent("tmp", isDirectory: true)
    }

    /// 扫描计数（测试断言）。
    private(set) var scanCount = 0

    private let store: UsageStoring
    private let tmpDirectory: URL
    private let fileManager: FileManager
    private let scheduler: RepeatingScheduling
    private let watcher: DirectoryWatching
    private let scanInterval: TimeInterval
    private let queue = DispatchQueue(label: "omniForge.tokenUsage.geminiCollector", qos: .utility)
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 扫描信号合并：scanning = 已排队/正在执行的扫描；扫描中收到的信号置 rescanRequested。
    private var scanning = false
    private var rescanRequested = false
    private var backfillCompleted = false

    init(
        store: UsageStoring,
        tmpDirectory: URL = GeminiUsageCollector.defaultTmpDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = GeminiUsageCollector.defaultScanInterval
    ) {
        self.store = store
        self.tmpDirectory = tmpDirectory
        self.fileManager = fileManager
        self.scheduler = scheduler
        self.watcher = watcher
        self.scanInterval = scanInterval
    }

    // MARK: - UsageCollecting

    /// 测试环境检测（仓库既有约定：与 Codex/Claude 采集器一致）。
    ///
    /// `swift test` 下 `XCTestConfigurationFilePath` 不存在，故以进程名 `xctest` 兜底；
    /// 测试进程里 `FeatureRuntime` 会按生产接线启动 TokenUsageManager — 若对真实
    /// `~/.gemini` 目录扫描会读到用户正在写入的会话并与真实应用争用同一 GRDB 库。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）目录构造。
    private var usesRealUserDirectories: Bool {
        tmpDirectory == GeminiUsageCollector.defaultTmpDirectory()
    }

    func start() {
        guard !started else { return }
        started = true
        guard !(isRunningUnitTests && usesRealUserDirectories) else { return }
        // 只监听 tmp 根（新项目子目录出现时 watcher 自己补挂；深层消息写入由定时兜底覆盖）。
        watcher.startWatching(url: tmpDirectory) { [weak self] in
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

    /// 线程安全：等待串行队列排空（测试用）。
    func waitForIdle() {
        queue.sync {}
    }

    // MARK: - 扫描调度（信号与解析分离 + 信号合并）

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
        let files = Self.enumerateSessionFiles(in: tmpDirectory, fileManager: fileManager)
        guard !files.isEmpty else { return }

        var cursors = store.loadCursors()
        var seen = store.loadSeenKeys()
        var newSeen = Set<String>()
        let aggregator = UsageAggregator { [store] key in
            store.loadBucket(key)
        }

        for fileURL in files {
            guard let snapshot = readSnapshot(
                fileURL: fileURL,
                previous: cursors[fileURL.path],
                fileManager: fileManager
            ) else { continue }
            var baseline: GeminiMessageTokens?
            for message in snapshot.decoded.messages ?? [] {
                processMessage(
                    message,
                    baseline: &baseline,
                    aggregator: aggregator,
                    seen: &seen,
                    newSeen: &newSeen
                )
            }
            cursors[fileURL.path] = snapshot.cursor
            store.storeCursor(path: fileURL.path, cursor: snapshot.cursor)
        }

        for state in aggregator.drainTouched() {
            store.upsertBucket(state)
        }
        guard !newSeen.isEmpty else { return }
        seen.formUnion(newSeen)
        store.storeSeenKeys(seen, asOf: Date())
    }

    /// 单条消息处理（隐私：只触碰已声明的身份/时间/模型/用量字段）。
    ///
    /// 差量基线规则（参考 parseGeminiIncremental）：
    /// - 有 tokens 的消息一律推进基线（含无 id / 无时间戳 / 已见消息）；
    /// - 无 tokens 的消息（系统消息等）不推进基线；
    /// - 只有「有 id + 有时间戳 + 差量非全零 + 未见」的消息计数入桶。
    private func processMessage(
        _ message: GeminiSessionMessage,
        baseline: inout GeminiMessageTokens?,
        aggregator: UsageAggregator,
        seen: inout Set<String>,
        newSeen: inout Set<String>
    ) {
        guard let tokens = message.tokens else { return }
        let previous = baseline
        baseline = tokens
        guard let delta = GeminiUsageProcessing.delta(current: tokens, previous: previous) else {
            return
        }
        guard let key = GeminiUsageProcessing.eventKey(messageID: message.id) else { return }
        guard !seen.contains(key), !newSeen.contains(key) else { return }
        guard let bucketStart = GeminiUsageProcessing.bucketStart(from: message.timestamp) else { return }
        guard let usage = GeminiUsageProcessing.normalized(from: delta) else { return }
        newSeen.insert(key)
        aggregator.ingest(
            usage: usage,
            conversationDelta: 1,
            key: UsageBucketKey(
                provider: provider,
                model: GeminiUsageProcessing.modelName(message.model),
                bucketStart: bucketStart
            )
        )
    }

    // MARK: - 快照读取与文件枚举

    /// 整文件读 + 游标判定：`{inode, size}` 一致 → 未变化跳过；inode/size 变化（含截断）→ 整读。
    /// 坏 JSON → nil（保留旧游标，等下一次重写后再试）。
    private func readSnapshot(
        fileURL: URL,
        previous cursor: JSONLCursor?,
        fileManager: FileManager
    ) -> (decoded: GeminiSessionFile, cursor: JSONLCursor)? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        let size = fileSize(from: attributes)
        let inode = fileInode(from: attributes)
        if let cursor, cursor.inode == inode, cursor.offset == size {
            return nil // 文件未变化
        }
        guard let data = fileManager.contents(atPath: fileURL.path),
              let decoded = try? JSONDecoder().decode(GeminiSessionFile.self, from: data) else {
            return nil // 坏 JSON：硬抗跳过，不更新游标
        }
        return (decoded, JSONLCursor(inode: inode, offset: size))
    }

    /// 递归收集 `session-*.json`（tmp 下各项目 chats 深目录），按路径稳定排序。
    static func enumerateSessionFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("session-") else {
                continue
            }
            // 统一解析符号链接前缀（/var → /private/var），保证游标 key 稳定。
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func fileSize(from attributes: [FileAttributeKey: Any]) -> UInt64 {
        (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func fileInode(from attributes: [FileAttributeKey: Any]) -> UInt64 {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
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
