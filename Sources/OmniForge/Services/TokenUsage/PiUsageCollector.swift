import Combine
import Foundation

/// Pi 用量采集器（A 类本地 JSONL，基于 JSONLUsageCollectorBase）。
///
/// 数据源：~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl。
/// 管线：目录监听 + 5 分钟定时兜底 → 串行队列扫描 → JSONL 增量读（inode/offset 游标）→
/// 行解码（只取 type/id/timestamp/message.role+usage/model 与 model_change 字段）→
/// 消息级去重 key → 半小时桶聚合；模型归属持久化到 JSONLCursor.model。
///
/// 去重 key：<provider>:<sessionId>:<message.id 或行号>；
/// 会话数：每个 session 文件计 1 次（首条真正入桶的 assistant 用量，按文件路径持久化 marker）。
///
/// 隐私红线（SPEC 2.6）：行解码只接触身份/模型/用量字段；prompt、消息正文
/// 与会话内容从不读取、绝不落盘。
class PiUsageCollector: JSONLUsageCollectorBase {
    /// Pi 会话根目录。
    ///
    /// 刻意不读取 PI_CODING_AGENT_DIR 等环境覆盖：Pi 与 Oh My Pi 共用该变量，
    /// 单一覆盖点会让两个采集器指向同一棵树并重复计数（对齐 tokscale omp.rs 的取舍）。
    class var defaultSessionsDirectory: URL {
        URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.pi/agent/sessions")
    }

    /// 扫描根目录（子类 OMP 复用同一解析逻辑，需要读取）。
    let sessionsDirectory: URL

    /// 采集器命名空间（= provider rawValue：pi / omp），用于去重 key 与会话计数 key。
    var namespace: String { provider.rawValue }

    init(
        store: UsageStoring,
        sessionsDirectory: URL = PiUsageCollector.defaultSessionsDirectory,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.sessionsDirectory = sessionsDirectory
        super.init(
            provider: .pi,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    /// 子类（Oh My Pi）指定 provider 的初始化器 — 解析逻辑完全复用。
    init(
        provider: TokenUsageProvider,
        sessionsDirectory: URL,
        store: UsageStoring,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.sessionsDirectory = sessionsDirectory
        super.init(
            provider: provider,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    // MARK: - 注入点

    /// 是否以默认（真实用户）目录构造（测试进程守卫）。
    override var usesRealDirectories: Bool {
        sessionsDirectory.standardizedFileURL == PiUsageCollector.defaultSessionsDirectory.standardizedFileURL
    }

    override var primaryWatchDirectory: URL? { sessionsDirectory }

    /// 递归收集 *.jsonl：Pi 子代理 / OMP 子代理目录内的会话文件同样是完整 session 文件。
    override func enumerateFiles() -> [URL] {
        JSONLUsageCollectorBase.enumerateFiles(in: sessionsDirectory, fileManager: fileManager) { url in
            url.pathExtension == "jsonl"
        }
    }

    // MARK: - 文件解析

    /// 单文件增量读：子类注入的 processLine 拿不到行号与完整文件状态，
    /// 这里改用自有状态（模型/会话 id/行号）直连 JSONLStreamReader。
    override func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        // 增量续读时 session 头/model_change 都在消费偏移之下：
        // 模型取游标持久化值，会话 id 先按路径推导（全量读到 header 时以头部 id 为准）。
        var state = FileScanState(
            model: previous?.model,
            sessionID: PiUsageProcessing.derivedSessionID(from: file)
        )
        guard let cursor = JSONLStreamReader.forEachLine(
            fileURL: file,
            previous: previous,
            fileManager: fileManager,
            consume: { line in
                consume(line, decoder: decoder, file: file, state: &state, scan: scan)
            }
        ) else {
            return nil
        }
        return JSONLCursor(inode: cursor.inode, offset: cursor.offset, model: state.model)
    }

    /// 单行处理：坏行跳过；只触碰已声明的身份/模型/用量字段（隐私最小化）。
    private func consume(
        _ line: String,
        decoder: JSONDecoder,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
    ) {
        // 行号只用于无 message.id 旧记录的去重兜底（每次增量读从 0 重新计数）。
        state.lineNumber += 1
        // 预筛：无关事件（正文/工具调用等）不触碰解码器（隐私最小化 + 性能）。
        guard line.contains("\"usage\"")
            || line.contains("\"model_change\"")
            || line.contains("\"session\"") else {
            return
        }
        guard let record = PiUsageProcessing.record(from: line, decoder: decoder) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }

        switch record.type {
        case "session":
            if let id = PiUsageProcessing.sessionID(from: record) {
                state.sessionID = id
            }
        case "model_change":
            if let change = PiUsageProcessing.modelChange(from: record) {
                state.model = change.model
            }
        case "message":
            ingest(record, file: file, state: &state, scan: scan)
        default:
            return
        }
    }

    /// assistant usage → 六列 → 去重 → 半小时桶（会话文件首条用量计 1 次会话）。
    private func ingest(
        _ record: PiSessionRecord,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
    ) {
        guard let message = record.message,
              message.role == "assistant",
              let usage = PiUsageProcessing.tokenUsage(from: message.usage),
              let bucketStart = PiUsageProcessing.bucketStart(from: record.timestamp) else {
            return
        }
        // 模型归属：最近 model_change（SPEC 4.2）；没有 model_change 的旧文件回退消息自带 model，
        // 并把回退值记入状态，使增量续读继续沿用（最终持久化到游标）。
        if state.model == nil {
            state.model = PiUsageProcessing.messageModel(from: message)
        }
        let dedupKey = PiUsageProcessing.deduplicationKey(
            namespace: namespace,
            sessionID: state.sessionID,
            messageID: record.id,
            lineNumber: state.lineNumber
        )
        // 已见消息直接跳过：不重复计 token，也不重复计会话。
        guard scan.markSeen(dedupKey) else { return }
        // 会话数：每个 session 文件只计 1 次（首条真正入桶的 assistant 用量）。
        let sessionMarker = PiUsageProcessing.sessionMarkerKey(
            namespace: namespace,
            filePath: file.path
        )
        let conversationDelta = scan.markSeen(sessionMarker) ? 1 : 0
        scan.aggregator.ingest(
            usage: usage,
            conversationDelta: conversationDelta,
            key: UsageBucketKey(
                provider: provider,
                model: state.model ?? PiUsageProcessing.defaultModel,
                bucketStart: bucketStart
            )
        )
    }
}

// MARK: - 每文件扫描状态

extension PiUsageCollector {
    /// 单文件解析状态：模型归属、会话 id（去重 key 前缀）与行号（无 id 兜底）。
    struct FileScanState {
        /// 最近 model_change 的模型（或消息自带模型兜底）；nil = 尚未见。
        var model: String?
        /// 会话 id：全量扫描取 session 头；增量扫描按路径推导。
        var sessionID: String?
        /// 本次增量读内的行号（从 1 开始）。
        var lineNumber: Int = 0
    }
}
