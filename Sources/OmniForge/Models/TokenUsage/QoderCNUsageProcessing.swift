import Foundation

// MARK: - Qoder CN transcript 行（Claude 兼容；隐私红线：正文不声明）

/// Qoder CN 的 Claude 兼容 transcript JSONL 单行 — 只声明身份/用量字段。
///
/// 2026-09 起 Qoder CN 把会话写成 Claude Code 兼容格式：助手行 `type: "assistant"`，
/// 用量在 `message.usage`（`input_tokens` / `output_tokens` /
/// `cache_creation_input_tokens` / `cache_read_input_tokens`），token 字段为整数。
/// `message.content` 只解码块 `type` 标记（判断 user 行是否含文本）；正文值从不读入。
struct QoderCNTranscriptEntry: Decodable, Equatable {
    let type: String?
    let sessionId: String?
    let uuid: String?
    let requestId: String?
    /// ISO8601 字符串（与 Claude Code transcript 一致）。
    let timestamp: String?
    let model: String?
    /// 根级 usage 兜底（部分兼容实现在根上输出）。
    let usage: Usage?
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
        /// 非 Claude 标准字段：部分兼容端点额外输出 reasoning 分项。
        /// 若存在，视为 `output_tokens` 的组成部分（与 Claude-fork rawUsage 语义一致）。
        let reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case reasoningTokens = "reasoning_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case uuid
        case requestId
        case timestamp
        case model
        case usage
        case message
    }
}

// MARK: - 解析纯函数

/// Qoder CN 行解析归一化 — Claude 语义（纯函数）。
///
/// 六列口径：`total = input + output`（reasoning 若存在单列且包含在总量内）；
/// 缓存读/写只分项展示，不计入 total。
/// 去重 key：`qoder-cn:<sessionId>:<message.id | requestId>`；无 id 时用「文件内
/// 绝对字节偏移」兜底（等价行号身份，增量续读与游标丢失重读都稳定）。
enum QoderCNUsageProcessing {
    static let defaultModel = "qoder-cn-unknown"
    /// 去重 key 前缀（跨 provider 共享 seen 集合，必须带前缀防与 Claude 原生 key 碰撞）。
    static let dedupePrefix = "qoder-cn"

    // MARK: 六列归一化

    /// 六列归一化；全零 → nil（不产生计数）。
    static func tokenUsage(from entry: QoderCNTranscriptEntry) -> TokenUsage? {
        guard let usage = entry.message?.usage ?? entry.usage else { return nil }
        let input = max(0, usage.inputTokens ?? 0)
        let cached = max(0, usage.cacheReadInputTokens ?? 0)
        let creation = max(0, usage.cacheCreationInputTokens ?? 0)
        let outputRaw = max(0, usage.outputTokens ?? 0)
        let reasoning = min(outputRaw, max(0, usage.reasoningTokens ?? 0))
        let output = max(0, outputRaw - reasoning)
        let total = input + output + reasoning
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: creation,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    // MARK: 模型

    /// 模型链：`message.model`（Qoder 规范位置）→ 行级 `model` → 默认。
    static func modelName(messageModel: String?, entryModel: String?) -> String {
        nonBlank(messageModel) ?? nonBlank(entryModel) ?? defaultModel
    }

    // MARK: 时间桶

    /// ISO8601 行时间戳 → UTC 半小时桶起点（复用 Claude 解析）。
    static func bucketStart(from timestamp: String?) -> Date? {
        ClaudeUsageProcessing.bucketStart(from: timestamp)
    }

    // MARK: 会话归属

    /// 会话 id：行内 `sessionId` → 文件路径推导。
    static func sessionID(from entry: QoderCNTranscriptEntry, file: URL) -> String {
        nonBlank(entry.sessionId) ?? sessionID(fromFile: file)
    }

    /// 文件路径推导会话 id：
    /// - 主会话 `<sessionId>.jsonl` → 文件名；
    /// - 子代理 `<sessionId>/subagents/agent-*.jsonl` → `subagents` 的上一级目录名。
    static func sessionID(fromFile file: URL) -> String {
        let components = file.standardizedFileURL.pathComponents
        if let index = components.lastIndex(of: "subagents"), index > 0 {
            return components[index - 1]
        }
        return file.deletingPathExtension().lastPathComponent
    }

    /// 是否子代理侧链文件（`<sessionId>/subagents/...`）。
    static func isSubagentFile(_ file: URL) -> Bool {
        file.standardizedFileURL.pathComponents.contains("subagents")
    }

    // MARK: 去重 key

    /// 助手往返级去重 key：`qoder-cn:<sessionId>:<message.id | requestId>`；
    /// 无 id 时用文件内绝对字节偏移兜底（`lineOffset` 为行起始字节）。
    static func deduplicationKey(
        sessionID: String,
        messageID: String?,
        requestID: String?,
        file: URL,
        lineOffset: UInt64
    ) -> String {
        if let id = nonBlank(messageID) {
            return "\(dedupePrefix):\(sessionID):\(id)"
        }
        if let id = nonBlank(requestID) {
            return "\(dedupePrefix):\(sessionID):\(id)"
        }
        return "\(dedupePrefix):\(sessionID):\(fileIdentity(file)):B\(lineOffset)"
    }

    /// 会话计数（user 文本行）去重 key：`qoder-cn:u:<sessionId>:<uuid>`；
    /// 无 uuid 时用绝对字节偏移兜底。
    static func userDeduplicationKey(
        sessionID: String,
        uuid: String?,
        file: URL,
        lineOffset: UInt64
    ) -> String {
        if let uuid = nonBlank(uuid) {
            return "\(dedupePrefix):u:\(sessionID):\(uuid)"
        }
        return "\(dedupePrefix):u:\(sessionID):\(fileIdentity(file)):B\(lineOffset)"
    }

    // MARK: - 工具

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 文件身份：末两层路径（区分主会话与子代理文件，不含绝对前缀）。
    private static func fileIdentity(_ file: URL) -> String {
        let components = file.standardizedFileURL.pathComponents
        guard !components.isEmpty else { return "unknown" }
        return components.suffix(2).joined(separator: "/")
    }
}
