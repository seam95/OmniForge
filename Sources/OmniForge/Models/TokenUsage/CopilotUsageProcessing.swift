import Foundation

// MARK: - session-store.db 行（只含身份/用量字段，正文永不读取）

/// `assistant_usage_events` 单行 + `sessions.created_at` 兜底（纯值，不含任何正文）。
///
/// 字段语义参考 tokscale `copilot_session_store.rs`（本机 schema 的权威参考）：
/// - `id`：事件主键（去重 key 首选）；
/// - `session_id` / `turn_index`：会话与轮次（轮次级会话计数）；
/// - `model` / `copilot_usage_model`：请求模型 / Copilot 实际计费模型（后者优先）；
/// - `input_tokens`：**含缓存读写的输入**；`cache_read_tokens` / `cache_write_tokens`
///   为其中的缓存分项；`reasoning_tokens` 为输出中的思考分项；
/// - `created_at`：事件时间；`session_created_at` 为会话创建时间（时间兜底）。
struct CopilotSessionUsageRow: Equatable {
    /// `assistant_usage_events.id`；旧库缺列时为 nil（回退「时间 + 用量签名」去重）。
    var eventID: Int64?
    var sessionID: String
    var turnIndex: Int64?
    var model: String?
    var copilotUsageModel: String?
    /// 含缓存读写的原始输入（归一化时扣除缓存分项）。
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    /// `assistant_usage_events.created_at`（ISO8601 或 SQLite `YYYY-MM-DD HH:MM:SS`）。
    var createdAt: String?
    /// LEFT JOIN `sessions.created_at`；无会话行/缺列时为 nil。
    var sessionCreatedAt: String?

    init(
        eventID: Int64? = nil,
        sessionID: String,
        turnIndex: Int64? = nil,
        model: String? = nil,
        copilotUsageModel: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        createdAt: String? = nil,
        sessionCreatedAt: String? = nil
    ) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.turnIndex = turnIndex
        self.model = model
        self.copilotUsageModel = copilotUsageModel
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.createdAt = createdAt
        self.sessionCreatedAt = sessionCreatedAt
    }
}

// MARK: - 入桶事件

/// 一条归一化后的用量记录（SQLite 行 / OTEL span → 六列 + 模型 + 半小时桶 + 去重 key）。
struct CopilotUsageEvent: Equatable {
    var usage: TokenUsage
    /// 恢复后的模型名（永不空：session-store 兜底 "auto"，OTEL 兜底 "unknown"）。
    var model: String
    /// UTC 半小时桶起点。
    var bucketStart: Date
    /// 跨扫描稳定去重 key（写入 message_seen）。
    var deduplicationKey: String
    /// 会话计数增量（同一会话轮次只计 1）。
    var conversationDelta: Int
}

// MARK: - 解析纯函数

/// Copilot 用量解析归一化 — 纯函数；SQL 行 / OTEL 记录 → 去重 key / 六列 / 半小时桶。
///
/// 两类数据源：
/// - **session-store.db**（`assistant_usage_events`）：行级 turn 用量，字段口径参考
///   tokscale `copilot_session_store.rs`；
/// - **OTEL JSONL**：Copilot CLI / VS Code Copilot Chat 的 OpenTelemetry 导出，
///   span/log 属性口径参考 tokscale `copilot.rs`。
///
/// 六列口径（`TokenUsage`）：
/// - `input` = 非缓存输入（session-store 扣除 cache_read + cache_write；OTEL 只扣除
///   cache_read，因为 OTel 的 input_tokens 只含缓存读）；
/// - `cached` = cache_read；`cacheCreation` = cache_write；`output` = 输出；
///   `reasoning` = 思考分项；
/// - `total` = input + output + reasoning。缓存读写是复用流量，不计入总量
///   （与 tokscale `TokenBreakdown.total()` 含缓存的展示口径不同，这里仅为总量展示口径差异）。
///
/// 隐私红线：只读取 token 数字、时间、模型与身份字段；prompt/正文/工具输出从不物化。
enum CopilotUsageProcessing {
    /// session-store.db 无模型信息时的兜底（Copilot CLI 自动选模，参考 tokscale 的 `auto`）。
    static let sessionStoreDefaultModel = "auto"
    /// OTEL 记录无模型信息时的兜底。
    static let otelDefaultModel = "unknown"
    /// OTEL 记录既无会话属性也无 trace 时的兜底会话名。
    static let unknownSessionID = "unknown-session"
    /// 去重 key 前缀（与 `TokenUsageProvider.copilot.rawValue` 一致）。
    static let deduplicationKeyPrefix = "copilot"

    // MARK: - session-store.db

    /// SQL 行 → 入桶事件。
    ///
    /// - 过滤：空会话 / 零用量 / 时间不可恢复（宁可漏计也不落入错误时间桶）；
    /// - 去重：同一批内按去重 key 只留首条（事件主键全局唯一，正常不会重复）；
    /// - 会话计数：按 `(session_id, turn_index)` 首次出现计 1（缺失 turn_index 时逐行计 1）。
    static func sessionStoreEvents(_ rows: [CopilotSessionUsageRow]) -> [CopilotUsageEvent] {
        var events: [CopilotUsageEvent] = []
        var emittedKeys = Set<String>()
        var countedTurns = Set<String>()

        for row in rows {
            guard let sessionID = trimmedNonEmpty(row.sessionID),
                  let usage = sessionStoreTokenUsage(row) else {
                continue
            }
            // 时间优先级：事件 created_at → 会话 created_at；两者都坏 → 丢弃该行。
            guard let timestamp = sessionStoreTimestampMilliseconds(row),
                  let bucketStart = bucketStart(fromMilliseconds: timestamp) else {
                continue
            }

            let model = sessionStoreModel(row)
            let key = sessionStoreDeduplicationKey(
                sessionID: sessionID,
                eventID: row.eventID,
                timestampMilliseconds: timestamp,
                usageSignature: usageSignature(model: model, usage: usage)
            )
            guard emittedKeys.insert(key).inserted else { continue }

            var conversationDelta = 1
            if let turn = row.turnIndex,
               !countedTurns.insert("\(sessionID)#\(turn)").inserted {
                conversationDelta = 0
            }

            events.append(CopilotUsageEvent(
                usage: usage,
                model: model,
                bucketStart: bucketStart,
                deduplicationKey: key,
                conversationDelta: conversationDelta
            ))
        }
        return events
    }

    /// 行六列归一化；五项全零 → nil（不产生计数）。
    ///
    /// `input_tokens` 是**含缓存读写的输入**：扣除 `cache_read_tokens` +
    /// `cache_write_tokens` 后得到非缓存输入（clamp ≥ 0）。`total` 不含缓存读写。
    static func sessionStoreTokenUsage(_ row: CopilotSessionUsageRow) -> TokenUsage? {
        let cacheRead = max(0, row.cacheReadTokens)
        let cacheWrite = max(0, row.cacheWriteTokens)
        let inclusiveInput = max(0, row.inputTokens)
        let output = max(0, row.outputTokens)
        let reasoning = max(0, row.reasoningTokens)
        // 先截断再相减，坏数据（缓存分项远大于输入）只归零，不触发溢出陷阱。
        let subtractable = min(inclusiveInput, safeAdd(cacheRead, cacheWrite))
        let nonCachedInput = inclusiveInput - subtractable
        let total = safeAdd(safeAdd(nonCachedInput, output), reasoning)
        guard nonCachedInput > 0 || cacheRead > 0 || cacheWrite > 0 || output > 0 || reasoning > 0 else {
            return nil
        }
        return TokenUsage(
            inputTokens: nonCachedInput,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    /// 模型优先级：`copilot_usage_model`（实际计费模型）→ `model` → `"auto"`。
    static func sessionStoreModel(_ row: CopilotSessionUsageRow) -> String {
        trimmedNonEmpty(row.copilotUsageModel)
            ?? trimmedNonEmpty(row.model)
            ?? sessionStoreDefaultModel
    }

    /// 行时间（epoch 毫秒）：`created_at` → `session_created_at`；不可解析 → nil。
    static func sessionStoreTimestampMilliseconds(_ row: CopilotSessionUsageRow) -> Double? {
        validatedMilliseconds(
            timestampMilliseconds(from: row.createdAt)
                ?? timestampMilliseconds(from: row.sessionCreatedAt)
        )
    }

    /// session-store 去重 key：`copilot:<sessionId>:event:<id>`；
    /// 事件 id 缺失时回退 `copilot:<sessionId>:ts:<ms>:<用量签名>`。
    static func sessionStoreDeduplicationKey(
        sessionID: String,
        eventID: Int64?,
        timestampMilliseconds: Double,
        usageSignature: String
    ) -> String {
        let prefix = "\(deduplicationKeyPrefix):\(sessionID)"
        if let eventID {
            return "\(prefix):event:\(eventID)"
        }
        return "\(prefix):ts:\(Int64(timestampMilliseconds.rounded())):\(usageSignature)"
    }

    /// 去重兜底签名：模型 + 六列（缓存读写各占一列；总量可由前三项推出，不重复计入）。
    static func usageSignature(model: String, usage: TokenUsage) -> String {
        "\(model)|\(usage.inputTokens)|\(usage.cachedInputTokens)|"
            + "\(usage.cacheCreationInputTokens)|\(usage.outputTokens)|\(usage.reasoningOutputTokens)"
    }

    // MARK: - OTEL JSONL

    /// 一行 JSONL → 字典；空行/坏行/非对象 → nil（逐行跳过，不影响整个文件）。
    static func parseOTELLine(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any] else {
            return nil
        }
        return record
    }

    /// 单文件 OTEL 记录 → 入桶事件（按文件行序传入）。
    ///
    /// 处理步骤（参考 tokscale `copilot.rs`）：
    /// 1. 第一遍收集 trace 级上下文（模型 / 会话可能出现在同 trace 的其它行）；
    /// 2. 第二遍识别四类用量记录并归一化；
    /// 3. 跨来源互斥：chat span > inference log > agent turn log > agent summary span
    ///    （同一 trace/response 只保留高优先级来源，避免一次请求重复计费）；
    /// 4. 解析模型/会话/时间并生成去重 key，同 key 快照合并（逐列取最大值）。
    ///
    /// - Parameters:
    ///   - records: 已解析的 JSON 对象（保持文件行序）。
    ///   - fallbackTimestampMilliseconds: 记录无可用时间时的文件 mtime 兜底。
    static func otelEvents(
        records: [[String: Any]],
        fallbackTimestampMilliseconds: Double?
    ) -> [CopilotUsageEvent] {
        let contexts = otelTraceContexts(records)
        var candidates: [OTELCandidate] = []
        for record in records {
            guard let candidate = otelCandidate(from: record) else { continue }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else { return [] }

        // 跨来源互斥集合：trace id / response id 任一命中即抑制低优先级来源。
        let chatTraces = traceIDs(in: candidates, kind: .chatSpan)
        let inferenceTraces = traceIDs(in: candidates, kind: .inferenceLog)
        let agentTurnTraces = traceIDs(in: candidates, kind: .agentTurnLog)
        let chatResponseIDs = responseIDs(in: candidates, kind: .chatSpan)
        let inferenceResponseIDs = responseIDs(in: candidates, kind: .inferenceLog)
        let agentTurnResponseIDs = responseIDs(in: candidates, kind: .agentTurnLog)

        var resolvedByKey: [String: ResolvedOTELCandidate] = [:]
        var keyOrder: [String] = []
        let fallbackTimestamp = validatedMilliseconds(fallbackTimestampMilliseconds)

        for candidate in candidates where shouldEmit(
            candidate,
            chatTraces: chatTraces,
            inferenceTraces: inferenceTraces,
            agentTurnTraces: agentTurnTraces,
            chatResponseIDs: chatResponseIDs,
            inferenceResponseIDs: inferenceResponseIDs,
            agentTurnResponseIDs: agentTurnResponseIDs
        ) {
            let context = candidate.traceID.flatMap { contexts[$0] }
            let model = candidate.model ?? context?.model ?? otelDefaultModel
            let sessionID = candidate.sessionID
                ?? context?.sessionID
                ?? candidate.traceID
                ?? unknownSessionID
            let ownTimestamp = validatedMilliseconds(candidate.timestampMilliseconds)
            guard let timestamp = ownTimestamp ?? fallbackTimestamp else { continue }

            let key: String
            if let recordID = globallyStableRecordID(candidate) {
                key = "\(deduplicationKeyPrefix):\(sessionID):\(recordID)"
            } else if let ownTimestamp {
                // 无全局身份时只接受自带时间：否则文件 mtime 变化会让旧记录换 key 重复计数。
                let signature = usageSignature(
                    model: model,
                    usage: normalizedOTELUsage(
                        rawInputTokens: candidate.rawInputTokens,
                        cacheReadTokens: candidate.cacheReadTokens,
                        cacheWriteTokens: candidate.cacheWriteTokens,
                        outputTokens: candidate.outputTokens,
                        reasoningTokens: candidate.reasoningTokens
                    )
                )
                key = "\(deduplicationKeyPrefix):\(sessionID):ts:"
                    + "\(Int64(ownTimestamp.rounded())):\(signature)"
            } else {
                continue
            }

            let resolved = ResolvedOTELCandidate(
                model: model,
                timestampMilliseconds: timestamp,
                rawInputTokens: candidate.rawInputTokens,
                cacheReadTokens: candidate.cacheReadTokens,
                cacheWriteTokens: candidate.cacheWriteTokens,
                outputTokens: candidate.outputTokens,
                reasoningTokens: candidate.reasoningTokens
            )
            if let existing = resolvedByKey[key] {
                resolvedByKey[key] = merged(existing, resolved)
            } else {
                resolvedByKey[key] = resolved
                keyOrder.append(key)
            }
        }

        var events: [CopilotUsageEvent] = []
        for key in keyOrder {
            guard let resolved = resolvedByKey[key],
                  let bucketStart = bucketStart(fromMilliseconds: resolved.timestampMilliseconds) else {
                continue
            }
            events.append(CopilotUsageEvent(
                usage: normalizedOTELUsage(resolved),
                model: resolved.model,
                bucketStart: bucketStart,
                deduplicationKey: key,
                conversationDelta: 1
            ))
        }
        return events
    }

    /// OTEL 六列归一化：
    /// - input = 原始输入 − cache_read（OTel 的 input_tokens 含缓存读）；
    /// - cache_write/cache_read 保留独立桶（计价口径，不从 input 重复扣）；
    /// - total = input + output + reasoning（缓存不计入总量）。
    static func normalizedOTELUsage(_ candidate: ResolvedOTELCandidate) -> TokenUsage {
        normalizedOTELUsage(
            rawInputTokens: candidate.rawInputTokens,
            cacheReadTokens: candidate.cacheReadTokens,
            cacheWriteTokens: candidate.cacheWriteTokens,
            outputTokens: candidate.outputTokens,
            reasoningTokens: candidate.reasoningTokens
        )
    }

    /// 原始五列 → 六列（候选/合并快照共用）。
    private static func normalizedOTELUsage(
        rawInputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int
    ) -> TokenUsage {
        let inclusiveInput = max(0, rawInputTokens)
        let cacheRead = max(0, cacheReadTokens)
        let cacheWrite = max(0, cacheWriteTokens)
        let output = max(0, outputTokens)
        let reasoning = max(0, reasoningTokens)
        let input = inclusiveInput - min(inclusiveInput, cacheRead)
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: safeAdd(safeAdd(input, output), reasoning)
        )
    }

    // MARK: - OTEL 记录分类

    /// OTEL 用量来源（跨来源互斥的优先级：chat > inference > agentTurn > agentSummary）。
    private enum OTELSourceKind {
        case chatSpan
        case inferenceLog
        case agentTurnLog
        case agentSummarySpan
    }

    /// 单条记录的中间态（解析完成、尚未回填 trace 上下文与去重 key）。
    private struct OTELCandidate {
        var kind: OTELSourceKind
        var traceID: String?
        var spanID: String?
        var responseID: String?
        var model: String?
        var sessionID: String?
        var turnIndex: Int64?
        var timestampMilliseconds: Double?
        var rawInputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
    }

    /// trace 级上下文（模型/会话可能只出现在同 trace 的其它记录上）。
    private struct OTELTraceContext {
        var model: String?
        var sessionID: String?
    }

    /// 已解析模型/会话/时间的候选（同 key 快照合并用）。
    struct ResolvedOTELCandidate: Equatable {
        var model: String
        var timestampMilliseconds: Double
        var rawInputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
    }

    /// 属性别名（与 tokscale 一致，兼容 OTel semconv 的不同版本）。
    private static let modelAttributeKeys = [
        "gen_ai.response.model",
        "gen_ai.request.model",
    ]
    /// 会话属性优先级（高 → 低；gen_ai.conversation.id 最稳定）。
    private static let sessionAttributeKeys = [
        "gen_ai.conversation.id",
        "copilot_chat.session_id",
        "copilot_chat.chat_session_id",
        "session.id",
        "github.copilot.interaction_id",
        "gen_ai.response.id",
    ]

    private static func otelTraceContexts(_ records: [[String: Any]]) -> [String: OTELTraceContext] {
        var contexts: [String: OTELTraceContext] = [:]
        for record in records {
            guard let traceID = traceIdentity(from: record) else { continue }
            var context = contexts[traceID] ?? OTELTraceContext()
            if let attributes = record["attributes"] as? [String: Any] {
                if context.model == nil {
                    context.model = firstNonEmptyAttribute(attributes, keys: modelAttributeKeys)
                }
                if context.sessionID == nil {
                    context.sessionID = firstNonEmptyAttribute(attributes, keys: sessionAttributeKeys)
                }
            }
            contexts[traceID] = context
        }
        return contexts
    }

    /// 单条记录 → 用量候选；非用量记录/零用量 → nil。
    private static func otelCandidate(from record: [String: Any]) -> OTELCandidate? {
        guard let attributes = record["attributes"] as? [String: Any],
              let kind = otelSourceKind(record, attributes: attributes) else {
            return nil
        }
        let rawInput = firstPositiveIntAttribute(attributes, keys: ["gen_ai.usage.input_tokens"])
        let cacheRead = firstPositiveIntAttribute(attributes, keys: [
            "gen_ai.usage.cache_read.input_tokens",
            "gen_ai.usage.cache_read_input_tokens",
        ])
        let cacheWrite = firstPositiveIntAttribute(attributes, keys: [
            "gen_ai.usage.cache_write.input_tokens",
            "gen_ai.usage.cache_creation.input_tokens",
            "gen_ai.usage.cache_write_input_tokens",
            "gen_ai.usage.cache_creation_input_tokens",
        ])
        let output = firstPositiveIntAttribute(attributes, keys: ["gen_ai.usage.output_tokens"])
        let reasoning = firstPositiveIntAttribute(attributes, keys: [
            "gen_ai.usage.reasoning.output_tokens",
            "gen_ai.usage.reasoning_tokens",
        ])
        guard rawInput > 0 || cacheRead > 0 || cacheWrite > 0 || output > 0 || reasoning > 0 else {
            return nil
        }
        let turnIndex = ["turn.index", "copilot_chat.turn.index"]
            .lazy
            .compactMap { int64Value(attributes[$0]) }
            .first
        return OTELCandidate(
            kind: kind,
            traceID: traceIdentity(from: record),
            spanID: spanIdentity(from: record),
            responseID: trimmedNonEmpty(attributes["gen_ai.response.id"] as? String),
            model: firstNonEmptyAttribute(attributes, keys: modelAttributeKeys),
            sessionID: firstNonEmptyAttribute(attributes, keys: sessionAttributeKeys),
            turnIndex: turnIndex,
            timestampMilliseconds: otelTimestampMilliseconds(from: record),
            rawInputTokens: rawInput,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            outputTokens: output,
            reasoningTokens: reasoning
        )
    }

    /// 记录分类：isSpan + name/operation 判定，非 span 记录按 event.name/body 判定。
    private static func otelSourceKind(
        _ record: [String: Any],
        attributes: [String: Any]
    ) -> OTELSourceKind? {
        let span = isSpanRecord(record)
        let operation = trimmedNonEmpty(attributes["gen_ai.operation.name"] as? String)
        let name = trimmedNonEmpty(record["name"] as? String)
        if span {
            if operation == "chat" || name?.hasPrefix("chat ") == true { return .chatSpan }
            if operation == "invoke_agent" || name?.hasPrefix("invoke_agent ") == true {
                return .agentSummarySpan
            }
            return nil
        }
        let eventName = trimmedNonEmpty(attributes["event.name"] as? String)
        let body = recordBody(record)
        if eventName == "gen_ai.client.inference.operation.details"
            || body?.hasPrefix("GenAI inference:") == true {
            return .inferenceLog
        }
        if eventName == "copilot_chat.agent.turn"
            || body?.hasPrefix("copilot_chat.agent.turn") == true {
            return .agentTurnLog
        }
        return nil
    }

    /// span 判定：显式 `type` 优先；VS Code 导出常省略 type，用 `name` + span 身份/时序推断。
    private static func isSpanRecord(_ record: [String: Any]) -> Bool {
        if let type = record["type"] as? String {
            return type == "span"
        }
        guard trimmedNonEmpty(record["name"] as? String) != nil else { return false }
        let hasIdentity = trimmedNonEmpty(record["spanId"] as? String) != nil
            || trimmedNonEmpty(record["traceId"] as? String) != nil
        let hasTiming = record["startTime"] != nil
            || record["endTime"] != nil
            || record["duration"] != nil
        return hasIdentity || hasTiming || record["kind"] != nil
    }

    /// W3C trace/span id：非空且非全零（全零是「无录制上下文」哨兵值）。
    private static func validSpanIdentity(_ value: Any?) -> String? {
        guard let raw = trimmedNonEmpty(value as? String),
              raw.contains(where: { $0 != "0" }) else {
            return nil
        }
        return raw
    }

    private static func traceIdentity(from record: [String: Any]) -> String? {
        validSpanIdentity(record["traceId"])
            ?? validSpanIdentity((record["spanContext"] as? [String: Any])?["traceId"])
    }

    private static func spanIdentity(from record: [String: Any]) -> String? {
        validSpanIdentity(record["spanId"])
            ?? validSpanIdentity((record["spanContext"] as? [String: Any])?["spanId"])
    }

    /// 跨扫描稳定的记录身份（`span:<trace>:<span>` / `turn:<trace>:<turn>`）；无 → nil。
    private static func globallyStableRecordID(_ candidate: OTELCandidate) -> String? {
        switch candidate.kind {
        case .chatSpan, .agentSummarySpan, .inferenceLog:
            guard let traceID = candidate.traceID, let spanID = candidate.spanID else { return nil }
            return "span:\(traceID):\(spanID)"
        case .agentTurnLog:
            guard let traceID = candidate.traceID, let turnIndex = candidate.turnIndex else {
                return nil
            }
            return "turn:\(traceID):\(turnIndex)"
        }
    }

    /// 跨来源互斥：高优先级来源出现过的 trace/response，低优先级来源不再计。
    private static func shouldEmit(
        _ candidate: OTELCandidate,
        chatTraces: Set<String>,
        inferenceTraces: Set<String>,
        agentTurnTraces: Set<String>,
        chatResponseIDs: Set<String>,
        inferenceResponseIDs: Set<String>,
        agentTurnResponseIDs: Set<String>
    ) -> Bool {
        func matches(_ set: Set<String>, _ value: String?) -> Bool {
            guard let value else { return false }
            return set.contains(value)
        }
        switch candidate.kind {
        case .chatSpan:
            return true
        case .inferenceLog:
            return !matches(chatTraces, candidate.traceID)
                && !matches(chatResponseIDs, candidate.responseID)
        case .agentTurnLog:
            return !matches(chatTraces, candidate.traceID)
                && !matches(inferenceTraces, candidate.traceID)
                && !matches(chatResponseIDs, candidate.responseID)
                && !matches(inferenceResponseIDs, candidate.responseID)
        case .agentSummarySpan:
            return !matches(chatTraces, candidate.traceID)
                && !matches(inferenceTraces, candidate.traceID)
                && !matches(agentTurnTraces, candidate.traceID)
                && !matches(chatResponseIDs, candidate.responseID)
                && !matches(inferenceResponseIDs, candidate.responseID)
                && !matches(agentTurnResponseIDs, candidate.responseID)
        }
    }

    private static func traceIDs(
        in candidates: [OTELCandidate],
        kind: OTELSourceKind
    ) -> Set<String> {
        Set(candidates.filter { $0.kind == kind }.compactMap(\.traceID))
    }

    private static func responseIDs(
        in candidates: [OTELCandidate],
        kind: OTELSourceKind
    ) -> Set<String> {
        Set(candidates.filter { $0.kind == kind }.compactMap(\.responseID))
    }

    /// 同 key 快照合并：token 逐列取最大（流式导出可能先写部分用量），时间取最早。
    private static func merged(
        _ existing: ResolvedOTELCandidate,
        _ duplicate: ResolvedOTELCandidate
    ) -> ResolvedOTELCandidate {
        var merged = existing
        merged.rawInputTokens = max(existing.rawInputTokens, duplicate.rawInputTokens)
        merged.cacheReadTokens = max(existing.cacheReadTokens, duplicate.cacheReadTokens)
        merged.cacheWriteTokens = max(existing.cacheWriteTokens, duplicate.cacheWriteTokens)
        merged.outputTokens = max(existing.outputTokens, duplicate.outputTokens)
        merged.reasoningTokens = max(existing.reasoningTokens, duplicate.reasoningTokens)
        merged.timestampMilliseconds = min(
            existing.timestampMilliseconds,
            duplicate.timestampMilliseconds
        )
        if merged.model == otelDefaultModel, duplicate.model != otelDefaultModel {
            merged.model = duplicate.model
        }
        return merged
    }

    /// OTEL 记录时间（epoch 毫秒），按导出格式依次尝试：
    /// startTime → endTime(-duration) → hrTime → time → timestamp → observedTimestamp → timeUnixNano。
    private static func otelTimestampMilliseconds(from record: [String: Any]) -> Double? {
        if let start = arrayTimestamp(record["startTime"]) {
            return start
        }
        if let end = arrayTimestamp(record["endTime"]) {
            if let duration = durationMilliseconds(record["duration"]), duration > 0 {
                return end - duration
            }
            return end
        }
        if let hrTime = arrayTimestamp(record["hrTime"]) ?? arrayTimestamp(record["_hrTime"]) {
            return hrTime
        }
        if let time = arrayTimestamp(record["time"]) {
            return time
        }
        if let timestamp = scalarTimestamp(record["timestamp"]) {
            return timestamp
        }
        if let observed = scalarTimestamp(record["observedTimestamp"]) {
            return observed
        }
        if let nanos = int64Value(record["timeUnixNano"]), nanos > 0 {
            return Double(nanos) / 1_000_000
        }
        return nil
    }

    /// `[秒, 纳秒]` 数组 → epoch 毫秒。
    private static func arrayTimestamp(_ value: Any?) -> Double? {
        guard let parts = value as? [Any], !parts.isEmpty,
              let seconds = int64Value(parts[0]) else {
            return nil
        }
        let nanos = parts.count > 1 ? (int64Value(parts[1]) ?? 0) : 0
        guard secondRange(nanos) else { return nil }
        return Double(seconds) * 1000 + Double(nanos) / 1_000_000
    }

    /// 标量时间按量级推断单位（纳秒/微秒/毫秒/秒）。
    private static func scalarTimestamp(_ value: Any?) -> Double? {
        guard let raw = int64Value(value) else { return nil }
        let magnitude = abs(raw)
        switch magnitude {
        case 100_000_000_000_000_000...:
            return Double(raw / 1_000_000)
        case 100_000_000_000_000...:
            return Double(raw / 1_000)
        case 100_000_000_000...:
            return Double(raw)
        default:
            return Double(raw) * 1000
        }
    }

    /// 时长：`[秒, 纳秒]` 数组，或微秒/毫秒标量（≥ 1e6 视为微秒）。
    private static func durationMilliseconds(_ value: Any?) -> Double? {
        if let parts = value as? [Any], !parts.isEmpty,
           let seconds = int64Value(parts[0]) {
            let nanos = parts.count > 1 ? (int64Value(parts[1]) ?? 0) : 0
            guard secondRange(nanos) else { return nil }
            return Double(seconds) * 1000 + Double(nanos) / 1_000_000
        }
        guard let raw = doubleValue(value), raw.isFinite, raw > 0 else { return nil }
        return raw >= 1_000_000 ? raw / 1_000_000 : raw
    }

    private static func secondRange(_ nanos: Int64) -> Bool {
        nanos >= 0 && nanos < 1_000_000_000
    }

    private static func recordBody(_ record: [String: Any]) -> String? {
        trimmedNonEmpty(record["body"] as? String)
            ?? trimmedNonEmpty(record["_body"] as? String)
    }

    private static func firstNonEmptyAttribute(
        _ attributes: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = trimmedNonEmpty(attributes[key] as? String) {
                return value
            }
        }
        return nil
    }

    /// 多个别名取第一个正数（0 视为缺省，与 tokscale `attr_i64_first` 一致）。
    private static func firstPositiveIntAttribute(
        _ attributes: [String: Any],
        keys: [String]
    ) -> Int {
        for key in keys {
            guard let raw = int64Value(attributes[key]), raw > 0 else { continue }
            return Int(clamping: raw)
        }
        return 0
    }

    // MARK: - 时间与数值工具

    /// 时间字符串 → epoch 毫秒。支持 RFC3339（带/不带小数秒）、
    /// 无时区 `YYYY-MM-DD HH:MM:SS(.SSS)`（按 UTC 解释）与纯数字秒/毫秒。
    static func timestampMilliseconds(from string: String?) -> Double? {
        guard let value = trimmedNonEmpty(string) else { return nil }
        if let date = isoFractional.date(from: value) {
            return date.timeIntervalSince1970 * 1000
        }
        if let date = isoPlain.date(from: value) {
            return date.timeIntervalSince1970 * 1000
        }
        for formatter in utcDateTimeFormatters {
            if let date = formatter.date(from: value) {
                return date.timeIntervalSince1970 * 1000
            }
        }
        if let numeric = Double(value), numeric > 0 {
            return numeric >= 1_000_000_000_000 ? numeric : numeric * 1000
        }
        return nil
    }

    /// epoch 毫秒 → UTC 半小时桶起点；非法/超界 → nil（统一走 UsageTimestampSanitizer）。
    static func bucketStart(fromMilliseconds milliseconds: Double) -> Date? {
        guard let seconds = UsageTimestampSanitizer.epochSeconds(fromMilliseconds: milliseconds) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// 外部时间戳清洗：非法（NaN/负数/超界）→ nil。
    static func validatedMilliseconds(_ milliseconds: Double?) -> Double? {
        guard let milliseconds, milliseconds.isFinite,
              UsageTimestampSanitizer.epochSeconds(fromMilliseconds: milliseconds) != nil else {
            return nil
        }
        return milliseconds
    }

    /// trim 后非空 → 原值；否则 nil。
    static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 外部数值桥接：NSNumber（JSONSerialization）/ String → Int64。
    static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    /// Int 求和防溢出（坏数据只影响计数上限，不触发运行时陷阱）。
    private static func safeAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 无时区日期时间按 UTC 解释（SQLite / Copilot CLI 均写 UTC）。
    private static let utcDateTimeFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
