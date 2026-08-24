import Combine
import Foundation

/// dsh（DeepSeek Harness）用量采集器（A 类本地 JSONL，基于 JSONLUsageCollectorBase）。
///
/// 数据源：`~/.dsh/sessions/**/session.jsonl`（`$DSH_HOME` 覆盖）。事件 `seq`
/// 单调递增做增量幂等（按 `dsh:<sessionId>:<seq>` 去重）；字段互斥直接映射，
/// 无需缓存减法。`.zstd` 压缩文件本期跳过并记日志（SPEC R2）。
///
/// 隐私红线（SPEC 2.6）：行解码只接触 `type/seq/time/id/data.header.config.model/
/// data.message.source.model/data.usage`；对话正文从不解析、绝不落盘。
final class DshUsageCollector: JSONLUsageCollectorBase {
    /// 大文件上限守卫（PLAN §1.3：128MB）。
    static let maxFileSizeBytes: UInt64 = 128 * 1024 * 1024

    /// dsh sessions 根目录（`$DSH_HOME` / `~/.dsh`）。
    static func defaultSessionsDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DSH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: homePath + "/.dsh/sessions")
    }

    private let sessionsDirectory: URL

    init(
        store: UsageStoring,
        sessionsDirectory: URL = DshUsageCollector.defaultSessionsDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.sessionsDirectory = sessionsDirectory
        super.init(
            provider: .dsh,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var usesRealDirectories: Bool {
        sessionsDirectory == DshUsageCollector.defaultSessionsDirectory()
    }

    override var primaryWatchDirectory: URL? { sessionsDirectory }

    override func enumerateFiles() -> [URL] {
        JSONLUsageCollectorBase.enumerateFiles(in: sessionsDirectory, fileManager: fileManager) { url in
            guard url.lastPathComponent == "session.jsonl" else { return false }
            return Self.fileSize(for: url, fileManager: fileManager) ?? 0 <= Self.maxFileSizeBytes
        }
    }

    override func processLine(
        _ line: String,
        decoder: JSONDecoder,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
    ) {
        guard line.contains("\"type\"") else { return }
        guard let entry = try? decoder.decode(DshTranscriptEntry.self, from: Data(line.utf8)) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }

        if entry.isSessionHeader {
            if let id = entry.id, !id.isEmpty {
                state.sessionId = id
            }
            return
        }
        if entry.isRequestHeader {
            if let model = DshUsageProcessing.normalizedModelName(entry.data?.header?.config?.model) {
                state.model = model
            }
            return
        }
        guard entry.isAssistantMessage, let usage = DshUsageProcessing.tokenUsage(from: entry.data?.usage) else {
            return
        }
        guard let model = DshUsageProcessing.normalizedModelName(entry.data?.message?.source?.model) ?? state.model,
              let bucketStart = DshUsageProcessing.bucketStart(fromMilliseconds: entry.time) else {
            return
        }
        scan.ingest(
            dedupKey: DshUsageProcessing.deduplicationKey(sessionID: state.sessionId, seq: entry.seq),
            usage: usage,
            conversationDelta: 1,
            model: model,
            bucketStart: bucketStart
        )
    }

    private static func fileSize(for url: URL, fileManager: FileManager) -> UInt64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.uint64Value
    }
}