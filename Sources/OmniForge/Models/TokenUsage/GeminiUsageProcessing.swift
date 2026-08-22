import Foundation

// MARK: - Gemini 会话消息（隐私红线：只声明身份/时间/模型/用量字段，正文从不物化）

/// Gemini `session-*.json`（整文件 JSON，非 JSONL）根节点 — 只声明会话身份与消息数组。
struct GeminiSessionFile: Decodable, Equatable {
    let sessionId: String?
    let messages: [GeminiSessionMessage]?
}

/// 单条消息的最小身份字段 — 未声明的键（content.text 等正文）由 JSONDecoder 直接丢弃。
struct GeminiSessionMessage: Decodable, Equatable {
    let id: String?
    let type: String?
    let timestamp: String?
    let model: String?
    let tokens: GeminiMessageTokens?
}

/// Gemini 每条消息的 token 累计快照（`content` 在 message 内、不入此结构）。
struct GeminiMessageTokens: Decodable, Equatable {
    var input: Int?
    var output: Int?
    var cached: Int?
    var thoughts: Int?
    var tool: Int?
    var total: Int?
}

// MARK: - 解析纯函数（参考 TokenTracker rollout-parser.test.js parseGeminiIncremental）

/// Gemini 会话解析归一化 — 纯函数；消息级累计差量 / 六列归一化（tool 并入 output、
/// total 重算含 cached）/ 去重 key / 半小时桶。
///
/// 口径说明（参考 08）：Gemini 把每消息的 **累计** token 快照写入会话 JSON；
/// 本文件统计必须对相邻消息做差量，否则跨 sync 重新解析整文件会重复计费。
/// 快照语义 — `cached` 为缓存读（独立列）；`tool` 并入 `output`；
/// Gemini 自报 `total` 可能不含 cached → 按四列重算。
enum GeminiUsageProcessing {
    static let defaultModel = "unknown"

    // MARK: 六列归一化

    /// 差量 → 六列（tool 并入 output、total 重算）；全零 → nil（不产生计数）。
    static func normalized(from counts: GeminiMessageTokens) -> TokenUsage? {
        let input = max(0, counts.input ?? 0)
        let cached = max(0, counts.cached ?? 0)
        let output = max(0, counts.output ?? 0) + max(0, counts.tool ?? 0)
        let reasoning = max(0, counts.thoughts ?? 0)
        let total = input + cached + output + reasoning
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    // MARK: 消息级累计差量

    /// 当前累计相对上一消息累计的差量；历史回退（累计不增反降）→ nil（保守跳过）。
    static func delta(current: GeminiMessageTokens?, previous: GeminiMessageTokens?) -> GeminiMessageTokens? {
        guard let current else { return nil }
        guard let previous else { return current }
        let fields: [(Int?, Int?)] = [
            (current.input, previous.input),
            (current.output, previous.output),
            (current.cached, previous.cached),
            (current.thoughts, previous.thoughts),
            (current.tool, previous.tool),
            (current.total, previous.total),
        ]
        for (left, right) in fields where (left ?? 0) < (right ?? 0) {
            return nil // 累计回退：无法确定差量
        }
        return GeminiMessageTokens(
            input: max(0, (current.input ?? 0) - (previous.input ?? 0)),
            output: max(0, (current.output ?? 0) - (previous.output ?? 0)),
            cached: max(0, (current.cached ?? 0) - (previous.cached ?? 0)),
            thoughts: max(0, (current.thoughts ?? 0) - (previous.thoughts ?? 0)),
            tool: max(0, (current.tool ?? 0) - (previous.tool ?? 0)),
            total: max(0, (current.total ?? 0) - (previous.total ?? 0))
        )
    }

    // MARK: 去重 key

    /// 消息级去重 key：`gemini:<messageID>`（会话 JSON 为重写式快照，重扫靠它幂等）。
    /// 无 id 的行不可去重（重扫会重复计费）→ 调用方保守跳过。
    static func eventKey(messageID: String?) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return "gemini:\(messageID)"
    }

    // MARK: 时间桶与模型

    /// 消息时间戳 → UTC 半小时桶起点（ISO 字符串）。
    static func bucketStart(from timestamp: String?) -> Date? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        guard let date = isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp) else {
            return nil
        }
        let seconds = Int(date.timeIntervalSince1970)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// 模型名：trim 后非空，否则回退 `unknown`。
    static func modelName(_ raw: String?) -> String {
        guard let raw else { return defaultModel }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}
