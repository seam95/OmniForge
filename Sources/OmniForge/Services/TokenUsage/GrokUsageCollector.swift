import Combine
import Foundation

/// grok（xAI CLI）用量采集器（A 类本地 JSONL，基于 JSONLUsageCollectorBase）。
///
/// 数据源：`~/.grok/sessions/<cwd>/<id>/updates.jsonl`（`GROK_HOME` 覆盖，路径
/// 编码见 `resolveGrokBuildSessions` 语义）。主路径按 `turn_completed.usage` 逐轮
/// 增量计数（`_meta.eventId` 去重、`modelUsage` 多模型拆分）；快照兜底仅用于
/// 无 `updates.jsonl` 的 sessions（`signals.json` 一次估算，`grok:fb:<id>` 幂等）。
///
/// 隐私红线（SPEC 2.6）：行解码只接触事件/用量/`_meta` 身份字段；`update.content`
/// 等正文从不声明解析、绝不落盘。
final class GrokUsageCollector: JSONLUsageCollectorBase {
    /// grok sessions 根目录（`$GROK_HOME` / `~/.grok`）。
    static func defaultSessionsDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: homePath + "/.grok/sessions")
    }

    private let sessionsDirectory: URL

    init(
        store: UsageStoring,
        sessionsDirectory: URL = GrokUsageCollector.defaultSessionsDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        self.sessionsDirectory = sessionsDirectory
        super.init(
            provider: .grok,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var usesRealDirectories: Bool {
        sessionsDirectory == GrokUsageCollector.defaultSessionsDirectory()
    }

    override var primaryWatchDirectory: URL? { sessionsDirectory }

    override func enumerateFiles() -> [URL] {
        JSONLUsageCollectorBase.enumerateFiles(in: sessionsDirectory, fileManager: fileManager) { url in
            url.lastPathComponent == "updates.jsonl" || url.lastPathComponent == "signals.json"
        }
    }

    override func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        if file.lastPathComponent == "signals.json" {
            return handleSignals(file: file, scan: scan)
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
        // 预筛：无关事件（正文/工具调用等）不触碰解码器。
        guard line.contains("turn_completed") || line.contains("_meta") else { return }
        guard let record = try? decoder.decode(GrokUpdateRecord.self, from: Data(line.utf8)) else {
            return // 坏行/无关行：逐行 try/catch 跳过（错误处理表）
        }
        // turn 无 modelUsage 时的回退模型：惰性读同会话 signals 一次，缓存到文件状态。
        if state.model == nil {
            state.model = sessionModel(for: file)
        }
        let fallback = state.model ?? GrokUsageProcessing.defaultModel
        for event in GrokUsageProcessing.turnEvents(from: record, fallbackModel: fallback, lineIndex: 0) {
            scan.ingest(
                dedupKey: event.dedupKey,
                usage: event.usage,
                conversationDelta: 1,
                model: event.model,
                bucketStart: GrokUsageProcessing.bucketStart(fromMilliseconds: event.timestampMs)
            )
        }
    }

    // MARK: - 快照兜底

    /// 处理 signals.json：同会话存在 updates.jsonl 时跳过（turn 路径优先，杜绝重叠）；
    /// 否则按 signals 总量做一次估算入桶（幂等 key `grok:fb:<sessionId>`）。始终返回
    /// 「已消费」游标，避免反复整读。
    private func handleSignals(file: URL, scan: ScanContext) -> JSONLCursor? {
        let sessionID = file.deletingLastPathComponent().lastPathComponent
        let updatesPath = file.deletingLastPathComponent().appendingPathComponent("updates.jsonl")
        guard !fileManager.fileExists(atPath: updatesPath.path),
              let data = try? Data(contentsOf: file),
              let signals = try? JSONDecoder().decode(GrokSignals.self, from: data) else {
            return consumedCursor(for: file, consumedBytes: 0)
        }
        let total = GrokUsageProcessing.effectiveSignalTotal(signals)
        guard total > 0 else {
            return consumedCursor(for: file, consumedBytes: UInt64(data.count))
        }
        let ts = GrokUsageProcessing.isoToMilliseconds(signals.lastActiveAt)
            ?? GrokUsageProcessing.isoToMilliseconds(signals.updatedAt)
            ?? Date().timeIntervalSince1970 * 1000
        guard let bucketStart = GrokUsageProcessing.bucketStart(fromMilliseconds: ts) else {
            return consumedCursor(for: file, consumedBytes: UInt64(data.count))
        }
        scan.ingest(
            dedupKey: "grok:fb:\(sessionID)",
            usage: GrokUsageProcessing.estimatedUsage(totalTokens: total),
            conversationDelta: 1,
            model: GrokUsageProcessing.signalModel(signals),
            bucketStart: bucketStart
        )
        return consumedCursor(for: file, consumedBytes: UInt64(data.count))
    }

    /// 同会话 signals.json 的 primaryModelId（作为 turn 无 modelUsage 时的回退模型）。
    private func sessionModel(for updatesFile: URL) -> String? {
        let signalsPath = updatesFile.deletingLastPathComponent().appendingPathComponent("signals.json")
        guard let data = try? Data(contentsOf: signalsPath),
              let signals = try? JSONDecoder().decode(GrokSignals.self, from: data) else {
            return nil
        }
        let model = GrokUsageProcessing.signalModel(signals)
        return model == GrokUsageProcessing.defaultModel ? nil : model
    }

    private func consumedCursor(for file: URL, consumedBytes: UInt64) -> JSONLCursor? {
        let attrs = try? fileManager.attributesOfItem(atPath: file.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return JSONLCursor(inode: inode, offset: consumedBytes)
    }
}