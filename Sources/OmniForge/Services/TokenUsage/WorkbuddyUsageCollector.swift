import Combine
import Foundation

/// WorkBuddy 用量采集器（A 类本地 JSONL + trace 兜底，基于 JSONLUsageCollectorBase）。
///
/// 数据源：`~/.workbuddy/projects/**/*.jsonl`（`$WORKBUDDY_HOME` 覆盖，transcript
/// 格式与 CodeBuddy 相同）+ `~/.workbuddy/traces/**/trace_*.json` 无损兜底。
/// 互斥：同一会话 JSONL 有 rawUsage（`workbuddy:detailed:<sid>`）
/// 或 trace 已消费（`workbuddy:traced:<sid>`）时另一来源跳过，绝不叠加。
///
/// 隐私红线（SPEC 2.6）：只接触身份/`providerData.rawUsage`/timestamp/model 与
/// trace 的模型/用量/时间戳字段；正文与执行步骤永不声明解析、绝不落盘。
final class WorkbuddyUsageCollector: JSONLUsageCollectorBase {
    /// WorkBuddy 主目录（`$WORKBUDDY_HOME` / `~/.workbuddy`）。
    static func defaultHomeDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["WORKBUDDY_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: homePath + "/.workbuddy")
    }

    /// 默认模型：settings.json 的 `model` 字段；缺失 → `auto`。
    static func defaultModel(
        homeDirectory: URL?,
        fileManager: FileManager = .default
    ) -> String {
        guard let homeDirectory else { return WorkbuddyUsageProcessing.defaultModel }
        let settingsURL = homeDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(WorkbuddySettings.self, from: data),
              let model = settings.model, !model.isEmpty else {
            return WorkbuddyUsageProcessing.defaultModel
        }
        return model
    }

    private struct WorkbuddySettings: Decodable {
        let model: String?
    }

    private let projectsDirectory: URL
    private let tracesDirectory: URL
    private let fallbackModel: String

    init(
        store: UsageStoring,
        homeDirectory: URL = WorkbuddyUsageCollector.defaultHomeDirectory(),
        projectsDirectory: URL? = nil,
        tracesDirectory: URL? = nil,
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.projectsDirectory = projectsDirectory ?? homeDirectory.appendingPathComponent("projects", isDirectory: true)
        self.tracesDirectory = tracesDirectory ?? homeDirectory.appendingPathComponent("traces", isDirectory: true)
        self.fallbackModel = WorkbuddyUsageCollector.defaultModel(homeDirectory: homeDirectory, fileManager: fileManager)
        super.init(
            provider: .workbuddy,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var usesRealDirectories: Bool {
        let home = WorkbuddyUsageCollector.defaultHomeDirectory()
        return projectsDirectory == home.appendingPathComponent("projects")
            && tracesDirectory == home.appendingPathComponent("traces")
    }

    override var primaryWatchDirectory: URL? { projectsDirectory }

    override func enumerateFiles() -> [URL] {
        let jsonl = JSONLUsageCollectorBase.enumerateFiles(in: projectsDirectory, fileManager: fileManager) {
            $0.pathExtension == "jsonl"
        }
        // JSONL 在前：trace 是无损兜底，不得胜过同会话的 rawUsage 明细（参考 rollout.js）。
        let traces = JSONLUsageCollectorBase.enumerateFiles(in: tracesDirectory, fileManager: fileManager) {
            $0.lastPathComponent.hasPrefix("trace_") && $0.pathExtension == "json"
        }
        return jsonl + traces
    }

    override func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        if file.lastPathComponent.hasPrefix("trace_") && file.pathExtension == "json" {
            return handleTrace(file: file, scan: scan)
        }
        return super.visit(file: file, previous: previous, decoder: decoder, scan: scan)
    }

    override func processLine(
        _ line: String,
        decoder: JSONDecoder,
        file: URL,
        state: inout FileScanState,
        scan: ScanContext
    ) {
        guard line.contains("rawUsage") else { return }
        guard let entry = try? decoder.decode(ClaudeForkTranscriptEntry.self, from: Data(line.utf8)),
              let rawUsage = entry.providerData?.rawUsage else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }
        let sessionID = (entry.sessionId?.isEmpty == false ? entry.sessionId : nil)
            ?? file.deletingPathExtension().lastPathComponent
        // 互斥：该会话已被 trace 兜底覆盖 → JSONL 不再计（防同会话叠加）。
        guard !scan.isSeen("workbuddy:traced:\(sessionID)") else { return }
        guard let usage = WorkbuddyUsageProcessing.tokenUsage(from: rawUsage),
              let timestampMs = entry.timestamp, timestampMs > 0,
              let bucketStart = WorkbuddyUsageProcessing.bucketStart(fromMilliseconds: timestampMs),
              let dedupKey = WorkbuddyUsageProcessing.deduplicationKey(
                  messageId: entry.providerData?.messageId,
                  uuid: entry.uuid,
                  id: entry.id,
                  sessionId: sessionID,
                  timestampMs: timestampMs
              ) else {
            return
        }
        // ingest 内部完成 markSeen 去重（预标记会让第二次 markSeen 短路）。
        scan.ingest(
            dedupKey: dedupKey,
            usage: usage,
            conversationDelta: 1,
            model: WorkbuddyUsageProcessing.modelName(
                provider: entry.providerData,
                entryModel: entry.model,
                fallback: fallbackModel
            ),
            bucketStart: bucketStart
        )
        // 会话有了明细 → 压制 trace；兼容旧版 entry.id 去重键（参考 rollout.js）。
        scan.markSeen("workbuddy:detailed:\(sessionID)")
        if let id = entry.id, !id.isEmpty, id != entry.providerData?.messageId {
            scan.markSeen("workbuddy:\(id)")
        }
    }

    // MARK: - trace 兜底

    private func handleTrace(file: URL, scan: ScanContext) -> JSONLCursor? {
        guard let data = try? Data(contentsOf: file),
              let document = try? JSONDecoder().decode(WorkbuddyTraceDocument.self, from: data),
              let trace = WorkbuddyUsageProcessing.traceUsage(
                  from: document,
                  fallbackModel: fallbackModel,
                  fileURL: file
              ),
              let bucketStart = WorkbuddyUsageProcessing.bucketStart(fromMilliseconds: trace.timestampMs) else {
            return consumedCursor(for: file)
        }
        // 互斥：同会话已有 JSONL 明细 → trace 跳过（JSONL 权威，防叠加）。
        guard !scan.isSeen("workbuddy:detailed:\(trace.sessionId)") else {
            return consumedCursor(for: file)
        }
        // 先标记（幂等），再以 nil 入桶：避免 ingest 内部二次 markSeen 短路。
        guard scan.markSeen("workbuddy:trace:\(trace.traceId)") else {
            return consumedCursor(for: file)
        }
        scan.ingest(
            dedupKey: nil,
            usage: trace.usage,
            conversationDelta: 1,
            model: trace.model,
            bucketStart: bucketStart
        )
        scan.markSeen("workbuddy:traced:\(trace.sessionId)")
        return consumedCursor(for: file)
    }

    private func consumedCursor(for file: URL) -> JSONLCursor? {
        let attrs = try? fileManager.attributesOfItem(atPath: file.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return JSONLCursor(inode: inode, offset: size)
    }
}