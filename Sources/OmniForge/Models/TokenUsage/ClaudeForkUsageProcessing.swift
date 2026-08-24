import Foundation

// MARK: - Claude-fork transcript 行（codebuddy / workbuddy 同格式；隐私红线：正文不声明）

/// CodeBuddy / WorkBuddy 共享的 transcript JSONL 单行 — 只声明身份/用量字段。
///
/// 用量挂在**任意**记录的 `providerData.rawUsage` 上（assistant 消息与 function_call
/// 记录均携带一次 LLM 往返用量）；`providerData.messageId` 为响应级 id，同往返的
/// function_call/message 记录共享，是最稳的去重 key（参考 TokenTracker rollout.js）。
struct ClaudeForkTranscriptEntry: Decodable, Equatable {
    let type: String?
    let sessionId: String?
    let uuid: String?
    let id: String?
    /// epoch 毫秒。
    let timestamp: Double?
    let model: String?
    let providerData: ProviderData?

    struct ProviderData: Decodable, Equatable {
        let messageId: String?
        let model: String?
        let requestModelId: String?
        let rawUsage: RawUsage?

        struct RawUsage: Decodable, Equatable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?
            let promptCacheHitTokens: Int?
            let promptCacheWriteTokens: Int?
            let promptTokensDetails: Details?
            let completionTokensDetails: Details?

            struct Details: Decodable, Equatable {
                let cachedTokens: Int?
                let reasoningTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case cachedTokens = "cached_tokens"
                    case reasoningTokens = "reasoning_tokens"
                }
            }

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case promptCacheHitTokens = "prompt_cache_hit_tokens"
                case promptCacheWriteTokens = "prompt_cache_write_tokens"
                case promptTokensDetails = "prompt_tokens_details"
                case completionTokensDetails = "completion_tokens_details"
            }
        }

        enum CodingKeys: String, CodingKey {
            case messageId = "messageId"
            case model
            case requestModelId = "requestModelId"
            case rawUsage = "rawUsage"
        }
    }
}

// MARK: - 解析纯函数

/// Claude-fork transcript 解析归一化 — codebuddy / workbuddy 共享（PLAN 期 2）。
///
/// 减法语义（参考 TokenTracker rollout）：
/// - `prompt_tokens` 为完整 prompt（含缓存）→ 减 cacheRead 与 cacheCreation；
/// - 缓存读有三种镜像（Anthropic `cache_read_input_tokens` / OpenAI
///   `prompt_tokens_details.cached_tokens` / DeepSeek `prompt_cache_hit_tokens`），取最大；
/// - `completion_tokens` 含 reasoning → 拆分出纯输出。
enum ClaudeForkUsageProcessing {
    static let defaultModel = "unknown"

    /// provider 间差异开关。
    struct Options: Equatable {
        /// codebuddy 缓存写多一路 `prompt_cache_write_tokens` 镜像。
        var includeCacheWriteMirror: Bool
        /// workbuddy 模型链多一路 `providerData.requestModelId`。
        var includeRequestModelId: Bool
    }

    static let codebuddy = Options(includeCacheWriteMirror: true, includeRequestModelId: false)
    static let workbuddy = Options(includeCacheWriteMirror: false, includeRequestModelId: true)

    // MARK: 六列归一化

    static func tokenUsage(
        from rawUsage: ClaudeForkTranscriptEntry.ProviderData.RawUsage?,
        options: Options
    ) -> TokenUsage? {
        guard let rawUsage else { return nil }
        let promptTokens = max(0, rawUsage.promptTokens ?? 0)
        let completionRaw = max(0, rawUsage.completionTokens ?? 0)
        let cachedTokens = max(
            max(0, rawUsage.promptTokensDetails?.cachedTokens ?? 0),
            max(0, rawUsage.promptCacheHitTokens ?? 0)
        )
        let cacheRead = max(cachedTokens, max(0, rawUsage.cacheReadInputTokens ?? 0))
        let cacheCreation = max(
            max(0, rawUsage.cacheCreationInputTokens ?? 0),
            options.includeCacheWriteMirror ? max(0, rawUsage.promptCacheWriteTokens ?? 0) : 0
        )
        // completion_tokens 含 reasoning（实测 reasoning 只在 completion_tokens_details 出现）。
        let reasoning = min(completionRaw, max(0, rawUsage.completionTokensDetails?.reasoningTokens ?? 0))
        let output = max(0, completionRaw - reasoning)
        let input = max(0, promptTokens - cacheRead - cacheCreation)
        let total = input + output + cacheRead + cacheCreation + reasoning
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    // MARK: 模型链

    /// 模型链：`providerData.model` →（workbuddy 可选 `requestModelId`）→ 行级 `model` → 回退。
    static func modelName(
        provider: ClaudeForkTranscriptEntry.ProviderData?,
        entryModel: String?,
        fallback: String,
        options: Options
    ) -> String {
        if let model = provider?.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model
        }
        if options.includeRequestModelId,
           let request = provider?.requestModelId,
           !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return request
        }
        if let model = entryModel, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model
        }
        return fallback
    }

    // MARK: 去重 key

    /// 往返级去重 key：`providerData.messageId` → `uuid` → `id` → `sessionId:tsMs`。
    /// 无任何 id → nil（调用方保守跳过，防游标丢失重读重复计费）。
    static func deduplicationKey(
        provider: TokenUsageProvider,
        messageId: String?,
        uuid: String?,
        id: String?,
        sessionId: String?,
        timestampMs: Double?
    ) -> String? {
        let prefix = provider.rawValue
        if let messageId, !messageId.isEmpty {
            return "\(prefix):\(messageId)"
        }
        if let uuid, !uuid.isEmpty {
            return "\(prefix):\(uuid)"
        }
        if let id, !id.isEmpty {
            return "\(prefix):\(id)"
        }
        if let timestampMs, timestampMs > 0, let sessionId, !sessionId.isEmpty {
            return "\(prefix):\(sessionId):\(Int(timestampMs))"
        }
        return nil
    }

    // MARK: 时间桶

    /// 毫秒时间戳 → UTC 半小时桶起点。
    static func bucketStart(fromMilliseconds ms: Double?) -> Date? {
        guard let ms, ms > 0, ms.isFinite else { return nil }
        let seconds = Int(ms / 1000)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }
}