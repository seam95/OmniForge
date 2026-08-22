import Foundation

// MARK: - 六列用量（隐私红线：只存 token 数字与时间）

/// 统一六列 token 用量（参考 02）：`input` 为纯非缓存输入，`cached` 为缓存读，
/// `cacheCreation` 为缓存写，`output` 为输出（Claude 口径已含 thinking），
/// `reasoning` 保留给分项口径（Claude 填 0），`total` 为四列之和。
struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var cacheCreationInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int

    static let zero = TokenUsage(
        inputTokens: 0,
        cachedInputTokens: 0,
        cacheCreationInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens + other.cacheCreationInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + other.reasoningOutputTokens,
            totalTokens: totalTokens + other.totalTokens
        )
    }
}

// MARK: - Claude transcript 行（仅解码标识与用量字段，永不触碰正文）

/// Claude Code JSONL 单行 — 只声明身份/用量字段。
///
/// 隐私红线（SPEC 2.6）：`message.content` 仅解码 `type` 标记（用于判断
/// 「用户是否说了话」），**text/input 等正文值从不被读入**；本结构不含任何
/// prompt、消息正文或会话内容的字段。
struct ClaudeTranscriptEntry: Decodable, Equatable {
    let type: String?
    let uuid: String?
    let requestId: String?
    let timestamp: String?
    /// 根级 usage/model 兜底（兼容部分客户端在根上输出）。
    let usage: Usage?
    let model: String?
    let message: Message?

    struct Message: Decodable, Equatable {
        let id: String?
        let model: String?
        let usage: Usage?
        let content: [ContentBlock]?

        var hasTextBlock: Bool {
            content?.contains { $0.type == "text" } ?? false
        }
    }

    /// 内容块 — 只解码 type，正文永不物化。
    struct ContentBlock: Decodable, Equatable {
        let type: String?
    }

    struct Usage: Decodable, Equatable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, uuid, requestId, timestamp, usage, model, message
    }
}

// MARK: - 解析纯函数（参考 02）

/// Claude 行解析归一化 — 纯函数；去重 key / 六列转换 / 半小时桶。
enum ClaudeUsageProcessing {
    /// 默认模型名（与 TokenTracker 的 DEFAULT_MODEL 对齐）。
    static let defaultModel = "unknown"

    /// 消息级去重 key：`message.id` 唯一即可，有 `requestId` 才拼接
    /// `msgId:reqId`（issue #64 血泪教训：兼容端点不返回 requestId，
    /// 强制要求会导致去重短路、重复计数 1.6~3.7 倍）。
    static func deduplicationKey(messageID: String?, requestID: String?) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        guard let requestID, !requestID.isEmpty else { return messageID }
        return "\(messageID):\(requestID)"
    }

    /// user 行（会话计数）去重 key：`u:<uuid>`（user 行没有 message.id）。
    static func userDeduplicationKey(uuid: String?) -> String? {
        guard let uuid, !uuid.isEmpty else { return nil }
        return "u:\(uuid)"
    }

    /// 六列归一化；全零 → nil（不产生计数）。
    static func tokenUsage(from entry: ClaudeTranscriptEntry) -> TokenUsage? {
        guard let usage = entry.message?.usage ?? entry.usage else { return nil }
        let input = max(0, usage.inputTokens ?? 0)
        let cached = max(0, usage.cacheReadInputTokens ?? 0)
        let creation = max(0, usage.cacheCreationInputTokens ?? 0)
        let output = max(0, usage.outputTokens ?? 0)
        let total = input + cached + creation + output
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: creation,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: total
        )
    }

    /// 模型名：trim 后非空，否则回退 `unknown`。
    static func modelName(_ raw: String?) -> String {
        guard let raw else { return defaultModel }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// 行时间戳 → UTC 半小时桶起点（`toUtcHalfHourStart` 的等价实现）。
    static func bucketStart(from timestamp: String?) -> Date? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        guard let date = isoDate(from: timestamp) else { return nil }
        return halfHourStart(for: date)
    }

    static func halfHourStart(for date: Date) -> Date {
        let seconds = Int(date.timeIntervalSince1970)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static func isoDate(from string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
