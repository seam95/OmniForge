import Combine
import Foundation

/// Claude Code 用量采集器（A 类本地 JSONL，基于 JSONLUsageCollectorBase 骨架）。
///
/// 管线：目录监听信号（DispatchSource）+ 5 分钟定时兜底 → 串行队列扫描 →
/// JSONL 增量读（inode/offset 游标）→ 行解码（只取身份/用量字段）→
/// 消息级去重 key → 半小时桶聚合（累计快照 upsert）→ 通知管理器刷新快照。
///
/// 隐私红线（SPEC 2.6）：行解码只接触 `message.id/model/usage/type/uuid` 与
/// 内容块的 `type` 标记；prompt、消息正文与会话内容从不读取、绝不落盘。
final class ClaudeUsageCollector: JSONLUsageCollectorBase {
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

    private let projectsDirectory: URL

    init(
        store: UsageStoring,
        projectsDirectory: URL = ClaudeUsageCollector.defaultProjectsDirectory,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.projectsDirectory = projectsDirectory
        super.init(
            provider: .claude,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var usesRealDirectories: Bool {
        projectsDirectory == ClaudeUsageCollector.defaultProjectsDirectory
    }

    override var primaryWatchDirectory: URL? { projectsDirectory }

    override func enumerateFiles() -> [URL] {
        JSONLUsageCollectorBase.enumerateFiles(in: projectsDirectory, fileManager: fileManager) {
            $0.pathExtension == "jsonl"
        }
    }

    override func processLine(
        _ line: String,
        decoder: JSONDecoder,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
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
            // 无 message.id 的行不给去重保护，照常计数。
            scan.ingest(
                dedupKey: ClaudeUsageProcessing.deduplicationKey(
                    messageID: entry.message?.id,
                    requestID: entry.requestId
                ),
                usage: usage,
                conversationDelta: 0,
                model: ClaudeUsageProcessing.modelName(entry.message?.model ?? entry.model),
                bucketStart: bucketStart
            )
        } else if entry.type == "user", !file.pathComponents.contains("subagents") {
            processUserLine(entry, scan: scan)
        }
    }

    /// 会话计数：仅主会话、带 text 块的 user 行；uuid 去重；桶键模型为 unknown（参考 02）。
    private func processUserLine(_ entry: ClaudeTranscriptEntry, scan: ScanContext) {
        guard entry.message?.hasTextBlock == true else { return }
        scan.ingest(
            dedupKey: ClaudeUsageProcessing.userDeduplicationKey(uuid: entry.uuid),
            usage: .zero,
            conversationDelta: 1,
            model: ClaudeUsageProcessing.defaultModel,
            bucketStart: ClaudeUsageProcessing.bucketStart(from: entry.timestamp)
        )
    }
}