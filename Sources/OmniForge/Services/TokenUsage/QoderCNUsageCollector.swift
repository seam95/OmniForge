import Combine
import Foundation

/// Qoder CN 用量采集器（A 类本地 JSONL，基于 JSONLUsageCollectorBase）。
///
/// 数据源：`~/.qoder-cn/projects/**/*.jsonl`（`$QODERCN_CONFIG_DIR` 覆盖 projects 父目录）。
/// 新版 Qoder CN（2026-09 起）把会话写成 Claude 兼容 transcript：每个 workspace 一个编码目录，
/// `<sessionId>.jsonl` 为主会话，`<sessionId>/subagents/agent-*.jsonl` 为子代理侧链。
/// 旧版 SQLite（`~/Library/Application Support/QoderCN/SharedClientCache/cache/db/local.db`）
/// 本机不存在，按 YAGNI 跳过；未来如需兼容，可在 `SQLiteUsageCollectorBase` 上另建采集器，
/// 本采集器不读旧库。
///
/// 口径：`total = input + output`（reasoning 若存在单列并包含在总量内）；
/// 缓存读/写只分列展示，不计入 total。
/// 去重：`qoder-cn:<sessionId>:<message.id | requestId>`；无 id 时用文件内绝对
/// 字节偏移兜底（见 QoderCNUsageProcessing）。
/// 会话数：主会话（非 subagents）含 text 块的 user 行计 1；子代理文件只计 token，
/// 不计会话（避免同一会话被侧链重复计数）。
///
/// 隐私红线（SPEC 2.6）：行解码只接触身份/模型/用量/内容块 `type`；正文永不物化。
final class QoderCNUsageCollector: JSONLUsageCollectorBase {
    /// `~/.qoder-cn/projects`（`$QODERCN_CONFIG_DIR` 覆盖其父目录，与官方客户端一致）。
    static func defaultProjectsDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        if let override = environment["QODERCN_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        return home
            .appendingPathComponent(".qoder-cn", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    private let projectsDirectory: URL

    init(
        store: UsageStoring,
        projectsDirectory: URL = QoderCNUsageCollector.defaultProjectsDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.projectsDirectory = projectsDirectory
        super.init(
            provider: .qoderCN,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var usesRealDirectories: Bool {
        projectsDirectory.standardizedFileURL
            == QoderCNUsageCollector.defaultProjectsDirectory().standardizedFileURL
    }

    override var primaryWatchDirectory: URL? { projectsDirectory }

    override func enumerateFiles() -> [URL] {
        JSONLUsageCollectorBase.enumerateFiles(in: projectsDirectory, fileManager: fileManager) {
            $0.pathExtension == "jsonl"
        }
    }

    /// 覆盖 visit 以携带每行的**文件内绝对字节偏移**：无 id 行的去重 key 需要
    /// 跨增量续读/游标丢失重读都稳定的行身份，而基类只回传行文本。
    /// 复用同一 `JSONLStreamReader`，语义（inode/截断/半行回退）与基类一致。
    override func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        var state = newFileState(file: file, cursor: previous)
        var lineOffset = scanStartOffset(for: file, previous: previous)
        guard let cursor = JSONLStreamReader.forEachLine(
            fileURL: file,
            previous: previous,
            fileManager: fileManager,
            consume: { line in
                let currentOffset = lineOffset
                // JSONL 行以单个 \n 结尾：下一行起始偏移 = 本行字节数 + 换行。
                lineOffset += UInt64(line.utf8.count) + 1
                processLine(
                    line,
                    lineOffset: currentOffset,
                    decoder: decoder,
                    file: file,
                    state: &state,
                    scan: scan
                )
            }
        ) else {
            return nil
        }
        return JSONLCursor(inode: cursor.inode, offset: cursor.offset, model: state.model)
    }

    /// 本次增量读取的起始字节偏移（与 JSONLStreamReader 的 inode/截断判定一致）。
    private func scanStartOffset(for file: URL, previous: JSONLCursor?) -> UInt64 {
        guard let previous,
              let attrs = try? fileManager.attributesOfItem(atPath: file.path),
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              inode == previous.inode,
              previous.offset <= size else {
            return 0
        }
        return previous.offset
    }

    private func processLine(
        _ line: String,
        lineOffset: UInt64,
        decoder: JSONDecoder,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
    ) {
        guard line.contains("usage") || line.contains("user") else { return }
        guard let entry = try? decoder.decode(QoderCNTranscriptEntry.self, from: Data(line.utf8)) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }

        if entry.type == "assistant" {
            guard let usage = QoderCNUsageProcessing.tokenUsage(from: entry),
                  let bucketStart = QoderCNUsageProcessing.bucketStart(from: entry.timestamp) else {
                return // 零用量/无时间：跳过
            }
            let sessionID = QoderCNUsageProcessing.sessionID(from: entry, file: file)
            scan.ingest(
                dedupKey: QoderCNUsageProcessing.deduplicationKey(
                    sessionID: sessionID,
                    messageID: entry.message?.id,
                    requestID: entry.requestId,
                    file: file,
                    lineOffset: lineOffset
                ),
                usage: usage,
                conversationDelta: 0,
                model: QoderCNUsageProcessing.modelName(
                    messageModel: entry.message?.model,
                    entryModel: entry.model
                ),
                bucketStart: bucketStart
            )
        } else if entry.type == "user", !QoderCNUsageProcessing.isSubagentFile(file) {
            processUserLine(entry, file: file, lineOffset: lineOffset, scan: scan)
        }
    }

    /// 会话计数：仅主会话、带 text 块的 user 行；口径对齐 ClaudeUsageCollector。
    private func processUserLine(
        _ entry: QoderCNTranscriptEntry,
        file: URL,
        lineOffset: UInt64,
        scan: ScanContext
    ) {
        guard entry.message?.hasTextBlock == true,
              let bucketStart = QoderCNUsageProcessing.bucketStart(from: entry.timestamp) else {
            return
        }
        let sessionID = QoderCNUsageProcessing.sessionID(from: entry, file: file)
        scan.ingest(
            dedupKey: QoderCNUsageProcessing.userDeduplicationKey(
                sessionID: sessionID,
                uuid: entry.uuid,
                file: file,
                lineOffset: lineOffset
            ),
            usage: .zero,
            conversationDelta: 1,
            model: QoderCNUsageProcessing.defaultModel,
            bucketStart: bucketStart
        )
    }
}
