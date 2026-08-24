import Combine
import Foundation

/// CodeBuddy 用量采集器（A 类本地 JSONL，基于 JSONLUsageCollectorBase）。
///
/// 数据源：`~/.codebuddy/projects/**/*.jsonl`（`$CODEBUDDY_HOME` 覆盖）。用量挂在
/// 任意记录的 `providerData.rawUsage`（assistant 消息与 function_call 均携带一次
/// LLM 往返用量）；`providerData.messageId` 为往返级去重 key（PLAN 期 2 / R3：
/// 首版不接 IDE 日志镜像）。默认模型从 `~/.codebuddy/settings.json` 的 `model` 读。
///
/// 隐私红线（SPEC 2.6）：行解码只接触身份/`providerData.rawUsage`/timestamp/model；
/// 消息正文与工具参数从不声明解析、绝不落盘。
final class CodebuddyUsageCollector: JSONLUsageCollectorBase {
    /// CodeBuddy 主目录（`$CODEBUDDY_HOME` / `~/.codebuddy`）。
    static func defaultHomeDirectory(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CODEBUDDY_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: homePath + "/.codebuddy")
    }

    /// 默认模型：settings.json 的 `model` 字段；缺失 → `codebuddy-unknown`。
    static func defaultModel(
        homeDirectory: URL?,
        fileManager: FileManager = .default
    ) -> String {
        guard let homeDirectory else { return CodebuddyUsageProcessing.defaultModel }
        let settingsURL = homeDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(CodebuddySettings.self, from: data),
              let model = settings.model, !model.isEmpty else {
            return CodebuddyUsageProcessing.defaultModel
        }
        return model
    }

    private struct CodebuddySettings: Decodable {
        let model: String?
    }

    private let projectsDirectory: URL
    /// 惰性读一次 settings.json（默认模型）。
    private let fallbackModel: String

    init(
        store: UsageStoring,
        projectsDirectory: URL? = nil,
        homeDirectory: URL = CodebuddyUsageCollector.defaultHomeDirectory(),
        fileManager: FileManager = .default,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        watcher: DirectoryWatching = DispatchSourceDirectoryWatcher(),
        scanInterval: TimeInterval = JSONLUsageCollectorBase.defaultScanInterval
    ) {
        let projects = projectsDirectory ?? homeDirectory.appendingPathComponent("projects", isDirectory: true)
        self.projectsDirectory = projects
        self.fallbackModel = CodebuddyUsageCollector.defaultModel(homeDirectory: homeDirectory, fileManager: fileManager)
        super.init(
            provider: .codebuddy,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler,
            watcher: watcher
        )
    }

    override var usesRealDirectories: Bool {
        projectsDirectory == CodebuddyUsageCollector.defaultHomeDirectory().appendingPathComponent("projects")
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
        guard line.contains("rawUsage") else { return }
        guard let entry = try? decoder.decode(ClaudeForkTranscriptEntry.self, from: Data(line.utf8)),
              let rawUsage = entry.providerData?.rawUsage,
              let usage = CodebuddyUsageProcessing.tokenUsage(from: rawUsage),
              let timestampMs = entry.timestamp, timestampMs > 0,
              let bucketStart = CodebuddyUsageProcessing.bucketStart(fromMilliseconds: timestampMs) else {
            return // 坏行/零用量/无时间：逐行跳过（错误处理表）
        }
        let sessionID = (entry.sessionId?.isEmpty == false ? entry.sessionId : nil)
            ?? file.deletingPathExtension().lastPathComponent
        guard let dedupKey = CodebuddyUsageProcessing.deduplicationKey(
            messageId: entry.providerData?.messageId,
            uuid: entry.uuid,
            id: entry.id,
            sessionId: sessionID,
            timestampMs: timestampMs
        ) else {
            return // 无任何往返级 id → 不可去重，保守跳过（防游标丢失重读重复计费）
        }
        scan.ingest(
            dedupKey: dedupKey,
            usage: usage,
            conversationDelta: 1,
            model: CodebuddyUsageProcessing.modelName(
                provider: entry.providerData,
                entryModel: entry.model,
                fallback: fallbackModel
            ),
            bucketStart: bucketStart
        )
    }
}