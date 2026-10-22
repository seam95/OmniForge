import Combine
import Foundation

/// DeepSeek Harness（DSH）用量采集器 — A 类本地 JSONL（含 zstd 压缩）。
///
/// 数据源：<DSH_HOME>/sessions/<encoded-cwd>/<session-id>/session(.vN)?.jsonl(.zstd)?
/// - 每轮扫描对每个会话文件做全量解析，用内存 (size, mtime) 指纹跳过未变化文件；
/// - 压缩文件由 ZstdFrameDecoder 只解压完整帧，torn tail 丢弃（下一轮重读）；
/// - 事件级去重键写入 message_seen，桶为累计快照，重复扫描幂等；
/// - fork 会话按 seedLength / end-seed 继承边界跳过父会话复制的事件。
///
/// 隐私红线：只解析 token 数字、事件时间、模型/provider 名与身份字段；
/// prompt、正文、工具输出从不物化，压缩数据只在内存中解压。
final class DshUsageCollector: JSONLUsageCollectorBase {
    /// DSH 会话根目录（DSH_HOME 覆盖，默认 ~/.dsh/sessions）。
    static var defaultSessionsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        if let override = ProcessInfo.processInfo.environment["DSH_HOME"], !override.isEmpty {
            base = URL(fileURLWithPath: override)
        } else {
            base = home.appendingPathComponent(".dsh", isDirectory: true)
        }
        return base.appendingPathComponent("sessions", isDirectory: true)
    }

    /// 会话日志文件名匹配：session.jsonl(.zstd) 与带版本号的 session.vN.jsonl(.zstd)。
    static func isSessionLog(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "session.jsonl" || name == "session.jsonl.zstd" { return true }
        return name.range(
            of: "^session\\.v[0-9]+\\.jsonl(\\.zstd)?$",
            options: .regularExpression
        ) != nil
    }

    /// 文件版本指纹：大小 + 修改时间；未变化则跳过解析。
    struct FileSignature: Equatable {
        var size: UInt64
        var modificationDate: Date
    }

    private let sessionsDirectory: URL
    /// 文件 → 指纹（进程内缓存；首次启动全部解析即回填）。
    private var fileSignatures: [String: FileSignature] = [:]

    init(
        store: UsageStoring,
        sessionsDirectory: URL = DshUsageCollector.defaultSessionsDirectory,
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

    /// 是否以默认（真实用户）目录构造（测试进程守卫）。
    override var usesRealDirectories: Bool {
        sessionsDirectory.standardizedFileURL == Self.defaultSessionsDirectory.standardizedFileURL
    }

    /// 监听根目录（会话文件在两层子目录内，追加写入不触发，靠 5 分钟兜底）。
    override var primaryWatchDirectory: URL? { sessionsDirectory }

    override func enumerateFiles() -> [URL] {
        JSONLUsageCollectorBase.enumerateFiles(in: sessionsDirectory, fileManager: fileManager) {
            Self.isSessionLog($0)
        }
    }

    /// 全量解析一个会话文件；返回 nil = 不推进游标（本采集器每次全量、靠消息级去重幂等）。
    override func visit(
        file: URL,
        previous: JSONLCursor?,
        decoder: JSONDecoder,
        scan: ScanContext
    ) -> JSONLCursor? {
        guard let signature = signature(of: file) else { return nil }
        if fileSignatures[file.path] == signature { return nil }
        guard let text = readText(from: file) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var state = DshFileState()
        // 第一遍只定位 fork 继承边界：end-seed 可能出现在继承前缀的末尾，
        // 必须在其之前的事件被处理前就知道边界，否则父会话复制的事件会被重复计费。
        prescanForkBoundary(lines, state: &state)
        // 第二遍处理全部事件（header/end-seed 重复设置同一值，幂等）。
        for line in lines {
            process(line: String(line), state: &state, scan: scan)
        }
        fileSignatures[file.path] = signature
        return nil
    }

    /// 预扫描：会话头（seedLength/isSeeded）与最后一个 inherited end-seed 的 seq。
    private func prescanForkBoundary(_ lines: [Substring], state: inout DshFileState) {
        for line in lines {
            guard let event = DshUsageProcessing.parseEvent(String(line)) else { continue }
            if !state.hasHeader, let header = DshUsageProcessing.sessionHeader(event) {
                state.hasHeader = true
                state.sessionID = header.id
                state.seedLength = header.seedLength
                state.isSeeded = header.isSeeded
            }
            if let cut = DshUsageProcessing.inheritedCut(event) {
                state.inheritedCut = cut
            }
        }
    }

    // MARK: - 读取

    private func signature(of file: URL) -> FileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        return FileSignature(size: size, modificationDate: modified)
    }

    /// 读取为文本：压缩文件只解压完整帧（torn tail 留给下一轮），未压缩直接解码。
    private func readText(from file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        if file.lastPathComponent.hasSuffix(".zstd") {
            guard data.count <= ZstdFrameDecoder.maxCompressedBytes else { return nil }
            return ZstdFrameDecoder.decodeIncrement(data).text
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 事件处理

    private func process(line: String, state: inout DshFileState, scan: ScanContext) {
        guard let event = DshUsageProcessing.parseEvent(line),
              let type = DshUsageProcessing.eventType(event) else {
            return
        }
        switch type {
        case "session":
            guard !state.hasHeader, let header = DshUsageProcessing.sessionHeader(event) else { return }
            state.hasHeader = true
            state.sessionID = header.id
            state.seedLength = header.seedLength
            state.isSeeded = header.isSeeded
        case "session/end-seed":
            if let cut = DshUsageProcessing.inheritedCut(event) {
                state.inheritedCut = cut
            }
        case "request/header":
            if let config = DshUsageProcessing.requestConfig(event) {
                if let model = config.model { state.fallbackModel = model }
                if let provider = config.provider { state.fallbackProvider = provider }
            }
        case "llm/retry-started":
            if let slot = DshUsageProcessing.retrySlot(event) {
                // 重试开启新调用：清空该槽位的旧 settlement，后续作为新调用计数。
                state.lastSettlement.removeValue(forKey: settlementKey(slot))
            }
        case "user/message":
            state.pendingUserTurn = true
        case "assistant/message", "assistant/attempt", "compaction/summary":
            handleUsageEvent(event, type: type, state: &state, scan: scan)
        default:
            break
        }
    }

    private func handleUsageEvent(
        _ event: [String: Any],
        type: String,
        state: inout DshFileState,
        scan: ScanContext
    ) {
        // fork 继承前缀过滤：父会话复制的事件不得重复计费。
        if let seq = DshUsageProcessing.seq(event) {
            if state.seedLength > 0, seq < state.seedLength { return }
            if let cut = state.inheritedCut, seq < cut { return }
        }

        guard let usageEvent = DshUsageProcessing.usageEvent(
            event,
            sessionID: state.sessionID,
            fallbackModel: state.fallbackModel,
            fallbackProvider: state.fallbackProvider
        ), let bucketStart = DshUsageProcessing.bucketStart(fromMilliseconds: usageEvent.timestampMs) else {
            return
        }

        // turn 起点 = 会话计数：每个 turn 的首条 assistant/message 计 1；
        // 无 turn 号时由最近的 user/message 标记消费一次。
        var conversationDelta = 0
        if type == "assistant/message" {
            if let turn = usageEvent.turn {
                if state.turnStarted.insert(turn).inserted {
                    conversationDelta = 1
                }
            } else if state.pendingUserTurn {
                state.pendingUserTurn = false
                conversationDelta = 1
            }
        }

        let slot = settlementKey(turn: usageEvent.turn, step: usageEvent.step)
        // 同一 (turn, step) 的后到 settlement 替换前一条：仅当本轮确实入过桶才扣回。
        if let slot, let previous = state.lastSettlement[slot], previous.ingested {
            scan.aggregator.ingest(
                usage: negated(previous.usage),
                conversationDelta: -previous.conversationDelta,
                key: previous.bucketKey
            )
        }

        let bucketKey = UsageBucketKey(provider: provider, model: usageEvent.model, bucketStart: bucketStart)
        let isNew = scan.markSeen(usageEvent.dedupKey)
        if isNew {
            scan.aggregator.ingest(
                usage: usageEvent.usage,
                conversationDelta: conversationDelta,
                key: bucketKey
            )
        }
        if let slot {
            state.lastSettlement[slot] = DshSettlement(
                bucketKey: bucketKey,
                usage: usageEvent.usage,
                conversationDelta: conversationDelta,
                ingested: isNew
            )
        }
    }

    // MARK: - 小工具

    private func settlementKey(_ slot: (turn: Int64, step: Int64)) -> String {
        settlementKey(turn: slot.turn, step: slot.step) ?? ""
    }

    private func settlementKey(turn: Int64?, step: Int64?) -> String? {
        guard let turn, let step else { return nil }
        return "\(turn):\(step)"
    }

    private func negated(_ usage: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: -usage.inputTokens,
            cachedInputTokens: -usage.cachedInputTokens,
            cacheCreationInputTokens: -usage.cacheCreationInputTokens,
            outputTokens: -usage.outputTokens,
            reasoningOutputTokens: -usage.reasoningOutputTokens,
            totalTokens: -usage.totalTokens
        )
    }
}

// MARK: - 单文件解析状态

/// 一个会话文件内的解析状态（fork 边界、路由兜底、turn/settlement 记账）。
private struct DshFileState {
    var hasHeader = false
    var sessionID: String?
    var seedLength: Int64 = 0
    var isSeeded = false
    var inheritedCut: Int64?
    var fallbackProvider: String?
    var fallbackModel: String?
    var lastSettlement: [String: DshSettlement] = [:]
    var turnStarted: Set<Int64> = []
    var pendingUserTurn = false
}

/// 已入桶 settlement（用于同一槽位后到样本的替换）。
private struct DshSettlement {
    var bucketKey: UsageBucketKey
    var usage: TokenUsage
    var conversationDelta: Int
    /// 本轮是否真正入过桶（历史已见事件被去重时为 false，不得扣回）。
    var ingested: Bool
}
