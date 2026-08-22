import Combine
import Foundation

/// Kimi 用量采集器（A 类本地 JSONL）。
///
/// 管线：目录监听信号 + 5 分钟定时兜底 → 串行队列扫描 →
/// wire.jsonl 增量读（inode/offset 游标）→ 行解码（只取事件类型/模型/用量字段）→
/// 消息级去重 key（step.end uuid / StatusUpdate message_id 分命名空间）→
/// 半小时桶聚合（累计快照 upsert，共用 GRDB store）→ 通知管理器刷新快照。
///
/// 数据源（参考 01/08）：Kimi Code `~/.kimi-code/sessions/**/agents/*/wire.jsonl`
/// + 旧版 kimi-cli `~/.kimi/sessions/**/wire.jsonl`；`KIMI_CODE_HOME` / `KIMI_HOME` 可覆盖。
///
/// 模型归属：`config.update` 的 `modelAlias` 剥离 `kimi-code/` 前缀后作为桶模型，
/// 并持久化到文件游标（`JSONLCursor.model`）— 增量续读时 config.update 已在消费
/// 偏移之下，靠游标中的模型保持归属；旧版无模型 → `unknown`。
///
/// 隐私红线（SPEC 2.6）：行解码只接触 type/time/timestamp/modelAlias/event.uuid/
/// usage 与 message.payload 的身份/用量字段；对话正文从不解析、绝不落盘。
final class KimiUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .kimi

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（SPEC 5.6：5 分钟）。
    static let defaultScanInterval: TimeInterval = 5 * 60

    /// Kimi Code 会话目录（`KIMI_CODE_HOME` / `KIMI_HOME` 覆盖，参考 01/08）。
    static func defaultCodeSessionsDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["KIMI_CODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true)
        }
        if let override = environment["KIMI_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: homePath + "/.kimi-code/sessions")
    }

    /// 旧版 kimi-cli 会话目录（`KIMI_HOME` 覆盖）。
    static func defaultLegacySessionsDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["KIMI_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: homePath + "/.kimi/sessions")
    }

    /// 扫描计数（测试断言）。
    private(set) var scanCount = 0

    private let store: UsageStoring
    private let codeSessionsDirectory: URL
    private let legacySessionsDirectory: URL
    private let fileManager: FileManager
    private let scheduler: RepeatingScheduling
    private let watcher: DirectoryWatching
    private let scanInterval: TimeInterval
    private let queue = DispatchQueue(label: "omniForge.tokenUsage.kimiCollector", qos: .utility)
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 扫描信号合并：scanning = 已排队/正在执行的扫描；扫描中收到的信号置 rescanRequested。
    private var scanning = false
    private var rescanRequested = false
    private var backfillCompleted = false

    init(
        store: UsageStoring,
        codeSessionsDirectory: URL = KimiUsageCollector.defaultCodeSessionsDirectory(),
        legacySessionsDirectory: URL = KimiUsageCollector.defaultLegacySessionsDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = KimiUsageCollector.defaultScanInterval
    ) {
        self.store = store
        self.codeSessionsDirectory = codeSessionsDirectory
        self.legacySessionsDirectory = legacySessionsDirectory
        self.fileManager = fileManager
        self.scheduler = scheduler
        self.watcher = watcher
        self.scanInterval = scanInterval
    }

    // MARK: - UsageCollecting

    /// 测试环境检测（仓库既有约定：与 Codex/Claude 采集器一致）。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）目录构造。
    private var usesRealUserDirectories: Bool {
        codeSessionsDirectory == KimiUsageCollector.defaultCodeSessionsDirectory()
            && legacySessionsDirectory == KimiUsageCollector.defaultLegacySessionsDirectory()
    }

    func start() {
        guard !started else { return }
        started = true
        guard !(isRunningUnitTests && usesRealUserDirectories) else { return }
        // 只监听 Kimi Code sessions 根（旧版目录写入由定时兜底覆盖）。
        watcher.startWatching(url: codeSessionsDirectory) { [weak self] in
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
        let files = Self.enumerateWireFiles(in: codeSessionsDirectory, fileManager: fileManager)
            + Self.enumerateWireFiles(in: legacySessionsDirectory, fileManager: fileManager)
        guard !files.isEmpty else { return }

        var cursors = store.loadCursors()
        var seen = store.loadSeenKeys()
        var newSeen = Set<String>()
        let aggregator = UsageAggregator { [store] key in
            store.loadBucket(key)
        }
        let decoder = JSONDecoder()

        for fileURL in files {
            let previous = cursors[fileURL.path]
            guard let outcome = JSONLStreamReader.read(
                fileURL: fileURL,
                previous: previous,
                fileManager: fileManager
            ) else { continue }
            // 增量续读时 config.update 可能在消费偏移之下 → 模型先取游标中的持久化值。
            var state = FileScanState(model: previous?.model)
            for line in outcome.lines {
                processLine(
                    line,
                    decoder: decoder,
                    state: &state,
                    aggregator: aggregator,
                    seen: &seen,
                    newSeen: &newSeen
                )
            }
            let cursor = JSONLCursor(
                inode: outcome.cursor.inode,
                offset: outcome.cursor.offset,
                model: state.model
            )
            cursors[fileURL.path] = cursor
            store.storeCursor(path: fileURL.path, cursor: cursor)
        }

        for state in aggregator.drainTouched() {
            store.upsertBucket(state)
        }
        guard !newSeen.isEmpty else { return }
        // 只写新见 key（seen_at = 首次实际看见时间），避免每次扫描把全量
        // key 的 seen_at 整体重写（截断退化、LRU 语义失真；参考 #09 评审 H4）。
        store.storeSeenKeys(newSeen, asOf: Date())
    }

    /// 单行处理：坏行跳过；只触碰已声明的身份/用量字段（隐私最小化）。
    private func processLine(
        _ line: String,
        decoder: JSONDecoder,
        state: inout FileScanState,
        aggregator: UsageAggregator,
        seen: inout Set<String>,
        newSeen: inout Set<String>
    ) {
        // 预筛：无关事件（对话正文/工具调用等）不触碰解码器。
        guard line.contains("config.update")
            || line.contains("context.append_loop_event")
            || line.contains("StatusUpdate") else {
            return
        }
        guard let entry = try? decoder.decode(KimiWireEntry.self, from: Data(line.utf8)) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }

        if entry.isConfigUpdate {
            if let model = KimiUsageProcessing.modelName(fromAlias: entry.modelAlias) {
                state.model = model
            }
            return
        }
        if entry.isStepEnd {
            ingest(
                usage: KimiUsageProcessing.normalized(from: entry.event?.usage),
                key: KimiUsageProcessing.eventKey(shape: .stepEnd, id: entry.event?.uuid),
                bucketStart: KimiUsageProcessing.bucketStart(fromMilliseconds: entry.time),
                model: state.model,
                aggregator: aggregator,
                seen: &seen,
                newSeen: &newSeen
            )
            return
        }
        if entry.isStatusUpdate {
            ingest(
                usage: KimiUsageProcessing.normalized(from: entry.message?.payload?.tokenUsage),
                key: KimiUsageProcessing.eventKey(shape: .statusUpdate, id: entry.message?.payload?.messageId),
                bucketStart: KimiUsageProcessing.bucketStart(fromSeconds: entry.timestamp),
                model: state.model,
                aggregator: aggregator,
                seen: &seen,
                newSeen: &newSeen
            )
        }
    }

    /// 去重 + 时间桶 + 计数入桶（无 key/无时间戳/零用量 → 保守跳过）。
    private func ingest(
        usage: TokenUsage?,
        key: String?,
        bucketStart: Date?,
        model: String?,
        aggregator: UsageAggregator,
        seen: inout Set<String>,
        newSeen: inout Set<String>
    ) {
        guard let key, let usage, let bucketStart else { return }
        guard !seen.contains(key), !newSeen.contains(key) else { return }
        newSeen.insert(key)
        aggregator.ingest(
            usage: usage,
            conversationDelta: 1,
            key: UsageBucketKey(
                provider: provider,
                model: model ?? KimiUsageProcessing.defaultModel,
                bucketStart: bucketStart
            )
        )
    }

    // MARK: - 文件枚举

    /// 递归收集 `wire.jsonl`（Kimi Code / 旧版会话深目录），按路径稳定排序。
    static func enumerateWireFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "wire.jsonl" else { continue }
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

// MARK: - 每文件扫描状态（模型归属）

extension KimiUsageCollector {
    struct FileScanState {
        /// config.update 模型别名（剥离前缀后）；nil = 尚未见/无（旧版 → unknown）。
        var model: String?

        init(model: String? = nil) {
            self.model = model
        }
    }
}
