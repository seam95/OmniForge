import Foundation

// MARK: - dsh session.jsonl 行（隐私红线：只声明身份/用量字段；正文永不物化）

/// DeepSeek Harness（dsh）`session.jsonl` 单行 — 只声明路由/用量字段。
///
/// 事件类型（参考 TokenTracker rollout `extractDshSessionUsage`）：
/// - `session`：会话头，`id` 记会话号；
/// - `request/header`：`data.header.config.model` 记请求级模型归属；
/// - `assistant/message`：`data.message.source.model`（或回退 header 模型）
///   携带 `data.usage`（字段互斥，直接映射，无需缓存减法）。
/// - `seq`：单调递增水位线（增量幂等）。
struct DshTranscriptEntry: Decodable, Equatable {
    let type: String?
    /// 单调水位线（分钟/秒级递增）；缺失行不做水位过滤。
    let seq: Double?
    /// 事件时间（epoch 毫秒）。
    let time: Double?
    /// 会话头 id。
    let id: String?
    var data: Data?

    var isSessionHeader: Bool { type == "session" }
    var isRequestHeader: Bool { type == "request/header" }
    var isAssistantMessage: Bool { type == "assistant/message" }

    struct Data: Decodable, Equatable {
        let header: Header?
        let message: Message?
        let usage: Usage?

        struct Header: Decodable, Equatable {
            let config: Config?
            struct Config: Decodable, Equatable {
                let model: String?
            }
        }

        struct Message: Decodable, Equatable {
            let source: Source?
            struct Source: Decodable, Equatable {
                let model: String?
            }
        }

        /// 字段互斥（无缓存减法前提）。
        struct Usage: Decodable, Equatable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadTokens: Int?
            let cacheWriteTokens: Int?
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "inputTokens"
                case outputTokens = "outputTokens"
                case cacheReadTokens = "cacheReadTokens"
                case cacheWriteTokens = "cacheWriteTokens"
                case reasoningTokens = "reasoningTokens"
            }
        }
    }
}

// MARK: - 解析纯函数

/// dsh 行解析归一化 — 纯函数；模型名清洗 / 六列映射 / 半小时桶 / 去重 key。
enum DshUsageProcessing {
    static let defaultModel = "unknown"

    /// 模型名清洗：剥离 provider 限定前缀（`deepseek/deepseek-v4-pro` → `deepseek-v4-pro`）。
    static func normalizedModelName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.lastIndex(of: "/") {
            let bare = String(trimmed[trimmed.index(after: slash)...])
            return bare.isEmpty ? nil : bare
        }
        return trimmed
    }

    /// 六列归一化 — 字段互斥直接映射（dsh 无需缓存减法）；全零 → nil。
    static func tokenUsage(from usage: DshTranscriptEntry.Data.Usage?) -> TokenUsage? {
        guard let usage else { return nil }
        let input = max(0, usage.inputTokens ?? 0)
        let cached = max(0, usage.cacheReadTokens ?? 0)
        let creation = max(0, usage.cacheWriteTokens ?? 0)
        let output = max(0, usage.outputTokens ?? 0)
        let reasoning = max(0, usage.reasoningTokens ?? 0)
        let total = input + cached + creation + output + reasoning
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

    /// 毫秒时间戳 → UTC 半小时桶起点。
    static func bucketStart(fromMilliseconds ms: Double?) -> Date? {
        guard let ms, ms > 0, ms.isFinite else { return nil }
        let seconds = Int(ms / 1000)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// 去重 key：`dsh:<sessionId>:<seq>`（缺任一时返回 nil → 不可去重，保守计数）。
    static func deduplicationKey(sessionID: String?, seq: Double?) -> String? {
        guard let seq, seq >= 0 else { return nil }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return "dsh:\(sessionID):\(Int(seq))"
    }
}