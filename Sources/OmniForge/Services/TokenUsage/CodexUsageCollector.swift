import Combine
import Foundation

/// Codex 用量采集器（A 类本地 JSONL）。
///
/// 管线：目录监听信号 + 5 分钟定时兜底 → 串行队列扫描 →
/// rollout JSONL 增量读（inode/offset 游标）→ 行解码（只取事件身份/用量字段）→
/// (session, timestamp, 用量签名) 去重 key → cached 减法归一化 →
/// 半小时桶聚合（累计快照 upsert，共用 GRDB store）→ 通知管理器刷新快照。
///
/// 数据源（参考 01/08）：`~/.codex/sessions/**/rollout-*.jsonl` + `archived_sessions/`；
/// `CODEX_HOME` 可覆盖。
///
/// 隐私红线（SPEC 2.6）：行解码只接触 type/timestamp/payload 的身份与 usage/模型字段；
/// prompt、消息正文与会话内容从不读取、绝不落盘。
final class CodexUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .codex

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（SPEC 5.6：5 分钟）。
    static let defaultScanInterval: TimeInterval = 5 * 60

    /// `CODEX_HOME` 覆盖默认 `~/.codex`（参考 01/08）。
    static func defaultCodexHomeURL(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: homePath + "/.codex")
    }

    static func defaultSessionsDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        defaultCodexHomeURL(homePath: homePath, environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultArchivedDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        defaultCodexHomeURL(homePath: homePath, environment: environment)
            .appendingPathComponent("archived_sessions", isDirectory: true)
    }

    /// 扫描计数（测试断言）。
    private(set) var scanCount = 0

    private let store: UsageStoring
    private let sessionsDirectory: URL
    private let archivedDirectory: URL
    private let fileManager: FileManager
    private let scheduler: RepeatingScheduling
    private let watcher: DirectoryWatching
    private let scanInterval: TimeInterval
    private let queue = DispatchQueue(label: "omniForge.tokenUsage.codexCollector", qos: .utility)
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 扫描信号合并：scanning = 已排队/正在执行的扫描；扫描中收到的信号置 rescanRequested。
    private var scanning = false
    private var rescanRequested = false
    private var backfillCompleted = false

    init(
        store: UsageStoring,
        sessionsDirectory: URL = CodexUsageCollector.defaultSessionsDirectory(),
        archivedDirectory: URL = CodexUsageCollector.defaultArchivedDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = CodexUsageCollector.defaultScanInterval
    ) {
        self.store = store
        self.sessionsDirectory = sessionsDirectory
        self.archivedDirectory = archivedDirectory
        self.fileManager = fileManager
        self.scheduler = scheduler
        self.watcher = watcher
        self.scanInterval = scanInterval
    }

    // MARK: - UsageCollecting

    /// 测试环境检测（仓库既有约定：参考 AppState / ClipboardHistoryManager）。
    ///
    /// `swift test`（本仓库标准命令）下 `XCTestConfigurationFilePath` 并不存在，
    /// 故以进程名 `xctest` 兜底（Xcode 运行器与 SwiftPM 运行器均可命中）。
    ///
    /// 单元测试进程里 `FeatureRuntime` 的 bootstrap 会按生产接线构建并启动
    /// `TokenUsageManager`；若此处对**真实用户目录**（默认 `~/.codex`）做扫描，
    /// 测试进程会读到用户正在写入的 rollout 文件、并与真实应用争用同一 GRDB
    /// 库（游标写入失败 → 反复全量重扫）。生产环境不受影响；
    /// 注入临时目录的单元测试也不受影响。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）目录构造。
    private var usesRealUserDirectories: Bool {
        sessionsDirectory == CodexUsageCollector.defaultSessionsDirectory()
    }

    func start() {
        guard !started else { return }
        started = true
        guard !(isRunningUnitTests && usesRealUserDirectories) else { return }
        // 只监听 sessions 根（新会话/归档目录的深层写入由定时兜底覆盖）。
        watcher.startWatching(url: sessionsDirectory) { [weak self] in
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
        let files = Self.enumerateRolloutFiles(in: sessionsDirectory, fileManager: fileManager)
            + Self.enumerateRolloutFiles(in: archivedDirectory, fileManager: fileManager)
        guard !files.isEmpty else { return }

        var cursors = store.loadCursors()
        var seen = store.loadSeenKeys()
        var newSeen = Set<String>()
        let aggregator = UsageAggregator { [store] key in
            store.loadBucket(key)
        }
        let decoder = JSONDecoder()

        for fileURL in files {
            let cursor = cursors[fileURL.path]
            guard let outcome = JSONLStreamReader.read(
                fileURL: fileURL,
                previous: cursor,
                fileManager: fileManager
            ) else { continue }
            var state = FileScanState(
                model: "",
                sessionID: Self.sessionIDFromPath(fileURL),
                isStreamStart: cursor == nil || outcome.reset
            )
            for line in outcome.lines {
                processLine(line, decoder: decoder, aggregator: aggregator, seen: &seen, newSeen: &newSeen, state: &state)
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

    /// 单行处理：坏行跳过；身份/用量字段解码；token_count → 增量入桶（去重 + cached 减法）。
    private func processLine(
        _ line: String,
        decoder: JSONDecoder,
        aggregator: UsageAggregator,
        seen: inout Set<String>,
        newSeen: inout Set<String>,
        state: inout FileScanState
    ) {
        // 预筛：无关事件（正文/工具调用等）不触碰解码器（隐私最小化 + 性能）。
        guard line.contains("token_count") || line.contains("turn_context") || line.contains("session_meta") else {
            return
        }
        guard let entry = try? decoder.decode(CodexRolloutEntry.self, from: Data(line.utf8)) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }

        switch entry.type {
        case "session_meta":
            if let id = entry.payload?.id, !id.isEmpty { state.sessionID = id }
            if let provider = entry.payload?.modelProvider, !provider.isEmpty {
                state.fallbackModel = provider
            }
        case "turn_context":
            if let model = entry.payload?.model, !model.isEmpty {
                state.model = model
            }
        case "event_msg":
            guard entry.isTokenCountEvent, let resource = entry.tokenCountResource else {
                return
            }
            let delta = CodexUsageProcessing.delta(
                last: resource.lastTokenUsage,
                total: resource.totalTokenUsage,
                previousTotal: state.previousTotal,
                isStreamStart: state.isStreamStart
            )
            guard let bucketStart = CodexUsageProcessing.bucketStart(from: entry.timestamp) else {
                state.advanceTotal(resource.totalTokenUsage)
                return
            }
            // 无 last 且无本文件上一轮累计（增量半流切入）：无法确定差值 → 保守跳过，
            // 但累计基线照常推进，避免后续事件把整段累计当增量重复计费。
            guard let delta else {
                state.advanceTotal(resource.totalTokenUsage)
                return
            }
            let key = CodexUsageProcessing.eventKey(
                sessionID: state.sessionID,
                timestamp: entry.timestamp,
                last: resource.lastTokenUsage,
                total: resource.totalTokenUsage
            )
            state.advanceTotal(resource.totalTokenUsage)
            if let key {
                guard !seen.contains(key), !newSeen.contains(key) else {
                    return // 已见事件：不重复计数
                }
                newSeen.insert(key)
            }
            aggregator.ingest(
                usage: delta,
                conversationDelta: 0,
                key: UsageBucketKey(
                    provider: provider,
                    model: CodexUsageProcessing.modelName(state.currentModel),
                    bucketStart: bucketStart
                )
            )
        default:
            return
        }
    }

    // MARK: - 文件枚举

    /// 递归收集 `rollout-*.jsonl`（sessions / archived_sessions 深目录），按路径稳定排序。
    static func enumerateRolloutFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else {
                continue
            }
            // 统一解析符号链接前缀（/var → /private/var），保证游标 key 稳定。
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 文件名中的会话 uuid 兜底（对齐 rolloutSessionIdFromPath；session_meta 通常优先）。
    static func sessionIDFromPath(_ fileURL: URL) -> String? {
        let name = fileURL.lastPathComponent
        let pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: name,
                  range: NSRange(location: 0, length: (name as NSString).length)
              ) else {
            return nil
        }
        return (name as NSString).substring(with: match.range)
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

// MARK: - 每文件扫描状态（模型/会话归属与累计基线）

extension CodexUsageCollector {
    struct FileScanState {
        /// turn_context 最近值（空 = 未见；currentModel 依次回退 session_meta.model_provider → unknown）。
        var model: String
        /// turn_context 未见时的模型兜底（session_meta.model_provider）。
        var fallbackModel: String?
        var sessionID: String?
        /// 本次扫描是否从文件头部开始（无游标 / inode 变化 / 截断重读）。
        var isStreamStart: Bool
        /// 本文件内最近一次 token_count 的 total_token_usage（差值基线）。
        var previousTotal: CodexTokenCounts?

        var currentModel: String {
            model.isEmpty ? (fallbackModel ?? CodexUsageProcessing.defaultModel) : model
        }

        mutating func advanceTotal(_ total: CodexTokenCounts?) {
            if let total { previousTotal = total }
        }
    }
}
