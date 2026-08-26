import Foundation

// MARK: - grok updates.jsonl 行（隐私红线：只声明身份/用量字段）

/// grok CLI `updates.jsonl` 单行 — 只声明事件/用量字段；`update` 正文内容不声明。
///
/// `turn_completed` 事件携带每轮真实 API 用量；`_meta.totalTokens` 为上下文窗口
/// 高水位（仅兜底路径使用）。`_meta.agentTimestampMs` 为事件毫秒时间戳。
struct GrokUpdateRecord: Decodable, Equatable {
    let timestamp: Double?
    let timestampMs: Double?
    let time: Double?
    let id: String?
    let eventId: String?
    let params: Params?

    struct Params: Decodable, Equatable {
        let sessionId: String?
        let meta: Meta?
        let update: Update?

        struct Meta: Decodable, Equatable {
            let totalTokens: Double?
            let eventId: String?
            let agentTimestampMs: Double?
            let timestampMs: Double?

            enum CodingKeys: String, CodingKey {
                case totalTokens = "totalTokens"
                case eventId = "eventId"
                case agentTimestampMs = "agentTimestampMs"
                case timestampMs = "timestampMs"
            }
        }

        struct Update: Decodable, Equatable {
            let sessionUpdate: String?
            let promptId: String?
            let usage: GrokTurnUsage?

            enum CodingKeys: String, CodingKey {
                case sessionUpdate = "sessionUpdate"
                case promptId = "prompt_id"
                case usage
            }
        }

        enum CodingKeys: String, CodingKey {
            case sessionId, meta = "_meta", update
        }
    }
}

/// 一轮 turn 的用量 — 顶层与 `modelUsage` 内同名条目复用。
struct GrokTurnUsage: Decodable, Equatable {
    let inputTokens: Double?
    let outputTokens: Double?
    let cachedReadTokens: Double?
    let reasoningTokens: Double?
    let totalTokens: Double?
    let modelUsage: [String: GrokTurnUsage]?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "inputTokens"
        case outputTokens = "outputTokens"
        case cachedReadTokens = "cachedReadTokens"
        case reasoningTokens = "reasoningTokens"
        case totalTokens = "totalTokens"
        case modelUsage
    }
}

/// grok `signals.json` 快照（兜底路径）：只声明模型/用量/时间戳字段。
struct GrokSignals: Decodable, Equatable {
    let primaryModelId: String?
    let modelsUsed: [String]?
    let model: String?
    let totalTokens: Double?
    let totalTokensBeforeCompaction: Double?
    let contextTokensUsed: Double?
    let lastActiveAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case primaryModelId = "primaryModelId"
        case modelsUsed = "modelsUsed"
        case model
        case totalTokens = "totalTokens"
        case totalTokensBeforeCompaction = "totalTokensBeforeCompaction"
        case contextTokensUsed = "contextTokensUsed"
        case lastActiveAt = "lastActiveAt"
        case updatedAt = "updatedAt"
    }
}

// MARK: - 解析纯函数

/// grok 行解析归一化 — 纯函数；turn 用量提取（含 modelUsage 多模型拆分）、
/// 时间秒/毫秒自适应、六列映射、模型规范化、兜底估算。
enum GrokUsageProcessing {
    static let defaultModel = "grok-build"
    /// 兜底估算的输入占比。
    static let estimatedInputRatio = 0.8

    /// 单个 turn 事件（按 modelUsage 拆分后）。
    struct TurnEvent: Equatable {
        var model: String
        var usage: TokenUsage
        var dedupKey: String
        /// 事件毫秒时间戳。
        var timestampMs: Double
    }

    // MARK: 模型规范化

    /// Free Build SKU 不得模糊匹配付费 grok-4.5 定价。
    static func canonicalizeModelName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return defaultModel }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("build-free") || lower.hasSuffix("-free") || lower.contains("free-tier") {
            return "grok-build-free"
        }
        if lower == "grok-4.5-build" || lower == "grok-4-5-build" {
            return "grok-4.5-build"
        }
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    // MARK: 时间解析

    /// 秒/毫秒自适应 → 毫秒；`< 1e10` 视为秒（对齐 grokTimestampToIso）。
    static func toMilliseconds(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }

    /// 事件时间戳（毫秒）→ UTC 半小时桶起点。
    static func bucketStart(fromMilliseconds ms: Double?) -> Date? {
        guard let ms, ms > 0, ms.isFinite else { return nil }
        let seconds = Int(ms / 1000)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// 毫秒时间戳 → 桶起点（语义与 bucketStart 相同，供兜底路径复用）。
    static func bucketStart(forEpochMs ms: Double) -> Date {
        let seconds = Int(ms / 1000)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /// ISO8601 快照时间（如 lastActiveAt）→ 毫秒；解析失败 nil。
    static func isoToMilliseconds(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let date = isoFractional.date(from: value) ?? isoPlain.date(from: value)
        return date.flatMap { $0.timeIntervalSince1970 * 1000 }
    }

    // MARK: turn 用量 → 六列

    /// 六列归一化：
    /// grok 的 `inputTokens` 含缓存命中 → 拆分出纯非缓存 input 与 cached；
    /// total 取「input + cached + creation + output」四列之和（OmniForge 桶语义）。
    static func tokenUsage(from usage: GrokTurnUsage?) -> TokenUsage? {
        guard let usage else { return nil }
        let inputRaw = max(0, usage.inputTokens ?? 0)
        let output = max(0, usage.outputTokens ?? 0)
        let cached = max(0, usage.cachedReadTokens ?? 0)
        let reasoning = max(0, usage.reasoningTokens ?? 0)
        guard inputRaw + output + cached + reasoning > 0 else { return nil }
        let input = max(0, inputRaw - cached)
        return TokenUsage(
            inputTokens: Int(input),
            cachedInputTokens: Int(cached),
            cacheCreationInputTokens: 0,
            outputTokens: Int(output),
            reasoningOutputTokens: Int(reasoning),
            totalTokens: Int(input + cached + output)
        )
    }

    // MARK: turn 事件提取

    /// 从一行记录提取 turn 事件（modelUsage 多模型拆分；否则用 fallbackModel）。
    /// 无事件 id（eventId/record.id/update.prompt_id 全缺）→ 返回空（不可去重，保守跳过）。
    static func turnEvents(
        from record: GrokUpdateRecord,
        fallbackModel: String,
        lineIndex: Int
    ) -> [TurnEvent] {
        guard let update = record.params?.update, update.sessionUpdate == "turn_completed",
              let usage = update.usage else {
            return []
        }
        let baseEventID = record.params?.meta?.eventId
            ?? record.eventId
            ?? record.id
            ?? update.promptId
        guard let baseEventID, !baseEventID.isEmpty else { return [] }

        let meta = record.params?.meta
        let timestampMs = toMilliseconds(meta?.agentTimestampMs)
            ?? toMilliseconds(meta?.timestampMs)
            ?? toMilliseconds(record.timestampMs)
            ?? toMilliseconds(record.timestamp)
            ?? toMilliseconds(record.time)
        guard let timestampMs else { return [] }

        let modelUsage = usage.modelUsage
        var events: [TurnEvent] = []
        if let modelUsage, !modelUsage.isEmpty {
            for (modelName, entry) in modelUsage {
                guard let tokens = tokenUsage(from: entry) else { continue }
                let model = canonicalizeModelName(modelName)
                events.append(TurnEvent(
                    model: model,
                    usage: tokens,
                    dedupKey: "grok:\(baseEventID)|\(model)",
                    timestampMs: timestampMs
                ))
            }
        }
        if events.isEmpty {
            guard let tokens = tokenUsage(from: usage) else { return [] }
            let model = canonicalizeModelName(fallbackModel)
            events.append(TurnEvent(
                model: model,
                usage: tokens,
                dedupKey: "grok:\(baseEventID)|\(model)",
                timestampMs: timestampMs
            ))
        }
        return events
    }

    // MARK: 快照兜底估算

    /// 快照有效总量（对齐 grokEffectiveTotalFromSignals）。
    static func effectiveSignalTotal(_ signals: GrokSignals?) -> Double {
        guard let signals else { return 0 }
        let beforeCompaction = max(0, signals.totalTokensBeforeCompaction ?? 0)
        let totalTokens = max(0, signals.totalTokens ?? 0)
        guard let contextTokensUsed = signals.contextTokensUsed else {
            return beforeCompaction + totalTokens
        }
        return max(totalTokens, beforeCompaction + max(0, contextTokensUsed))
    }

    /// 快照模型（primaryModelId → modelsUsed[0] → model → "grok-build"）。
    static func signalModel(_ signals: GrokSignals?) -> String {
        canonicalizeModelName(
            signals?.primaryModelId
                ?? signals?.modelsUsed?.first
                ?? signals?.model
        )
    }

    /// 总量差分 → 估算六列（输入占 80%，无缓存/推理；对齐 estimateGrokTokenDelta）。
    static func estimatedUsage(totalTokens: Double) -> TokenUsage {
        let total = totalTokens > 0 ? totalTokens : 0
        let input = Int((total * estimatedInputRatio).rounded())
        let output = Int(total) - input
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: Int(total)
        )
    }
}