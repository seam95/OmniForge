import Foundation

// MARK: - Kimi wire.jsonl 行（隐私红线：只声明事件类型/模型/用量字段，正文从不物化）

/// wire.jsonl 单行 — 只声明身份/用量字段；未声明键（对话正文等）由 JSONDecoder 丢弃。
///
/// 兼容两种协议（参考 TokenTracker parseKimiIncremental / parseKimiCodeIncremental）：
/// - Kimi Code（`~/.kimi-code/sessions/**/agents/*/wire.jsonl`）：`config.update` +
///   `context.append_loop_event`（step.end 带 usage，`time` 为 epoch 毫秒）。
/// - 旧版 kimi-cli（`~/.kimi/sessions/**/wire.jsonl`）：`message.type == StatusUpdate`，
///   `timestamp` 为 epoch 秒（含小数）。
struct KimiWireEntry: Decodable, Equatable {
    let type: String?
    /// Kimi Code 事件时间（epoch 毫秒）。
    let time: Double?
    /// 旧版 StatusUpdate 时间（epoch 秒）。
    let timestamp: Double?
    /// config.update：模型别名（如 `kimi-code/kimi-k2.6`）。
    let modelAlias: String?
    /// context.append_loop_event 载体。
    let event: Event?
    /// 旧版 StatusUpdate 载体（根上没有 type）。
    let message: Message?

    var isConfigUpdate: Bool { type == "config.update" }
    var isStepEnd: Bool { type == "context.append_loop_event" && event?.type == "step.end" }
    var isStatusUpdate: Bool { message?.type == "StatusUpdate" }

    struct Event: Decodable, Equatable {
        let type: String?
        let uuid: String?
        let usage: KimiWireTokenUsage?
    }

    struct Message: Decodable, Equatable {
        let type: String?
        let payload: Payload?
    }

    struct Payload: Decodable, Equatable {
        let messageId: String?
        let tokenUsage: KimiWireTokenUsage?

        enum CodingKeys: String, CodingKey {
            case messageId = "message_id"
            case tokenUsage = "token_usage"
        }
    }
}

/// 跨形状 union 的 token 用量字段（参考 TokenTracker 三种口径）。
struct KimiWireTokenUsage: Decodable, Equatable {
    /// Anthropic 形状：input_tokens / output_tokens / cache_read_input_tokens / cache_creation_input_tokens。
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?
    /// OpenAI 兼容形状：input_tokens_details.cached_tokens（cached 折叠进 input_tokens）。
    var cachedTokensFromDetails: Int?
    /// camelCase（kimi-code 0.6.0+）与旧版 StatusUpdate 形状：
    /// inputOther / input_other 等（inputOther 为纯非缓存输入）。
    var inputOther: Int?
    var inputCacheRead: Int?
    var inputCacheCreation: Int?
    var output: Int?

    init() {}

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokensSnake = "output_tokens"
        case outputTokensCamel = "output"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case inputOtherCamel = "inputOther"
        case inputOtherSnake = "input_other"
        case inputCacheReadCamel = "inputCacheRead"
        case inputCacheReadSnake = "input_cache_read"
        case inputCacheCreationCamel = "inputCacheCreation"
        case inputCacheCreationSnake = "input_cache_creation"
        case inputTokensDetails = "input_tokens_details"
    }

    private struct InputTokensDetails: Decodable {
        let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    /// 双键名兼容：旧版蛇形（input_other）与新版驼峰（inputOther）都接受。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokensSnake)
            ?? container.decodeIfPresent(Int.self, forKey: .outputTokensCamel)
        cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
        output = outputTokens
        inputOther = try container.decodeIfPresent(Int.self, forKey: .inputOtherCamel)
            ?? container.decodeIfPresent(Int.self, forKey: .inputOtherSnake)
        inputCacheRead = try container.decodeIfPresent(Int.self, forKey: .inputCacheReadCamel)
            ?? container.decodeIfPresent(Int.self, forKey: .inputCacheReadSnake)
        inputCacheCreation = try container.decodeIfPresent(Int.self, forKey: .inputCacheCreationCamel)
            ?? container.decodeIfPresent(Int.self, forKey: .inputCacheCreationSnake)

        if let details = try? container.decodeIfPresent(InputTokensDetails.self, forKey: .inputTokensDetails) {
            cachedTokensFromDetails = details.cachedTokens
        }
    }
}

// MARK: - 解析纯函数

/// Kimi wire.jsonl 解析归一化 — 纯函数；三种 usage 形状归一化 / 去重 key / 半小时桶 / 模型名。
enum KimiUsageProcessing {
    static let defaultModel = "unknown"

    /// 去重组：Kimi Code step.end（uuid）与旧版 StatusUpdate（message_id）分开命名空间。
    enum Shape {
        case stepEnd
        case statusUpdate
    }

    // MARK: 六列归一化

    /// 归一化（口径对齐 TokenTracker 三种形状）：
    /// - Anthropic 形状：input 与 cache_read 分列，**不**做减法；
    /// - OpenAI 兼容：cached 折叠进 input_tokens → 减法；
    /// - camelCase / 旧版：inputOther/input_other 已是纯非缓存输入，不做减法。
    static func normalized(from usage: KimiWireTokenUsage?) -> TokenUsage? {
        guard let usage else { return nil }
        let input: Int
        let cached: Int
        let creation: Int
        let output: Int
        if let rawInput = usage.inputTokens {
            if let folded = usage.cachedTokensFromDetails {
                input = max(0, rawInput - folded)
                cached = folded
                creation = 0
            } else {
                input = max(0, rawInput)
                cached = max(0, usage.cacheReadInputTokens ?? 0)
                creation = max(0, usage.cacheCreationInputTokens ?? 0)
            }
            output = max(0, usage.outputTokens ?? 0)
        } else {
            input = max(0, usage.inputOther ?? 0)
            cached = max(0, usage.inputCacheRead ?? 0)
            creation = max(0, usage.inputCacheCreation ?? 0)
            output = max(0, usage.output ?? 0)
        }
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

    // MARK: 去重 key

    /// 消息级去重 key；无 id 的行不可去重（增量重扫会重复计费）→ 调用方保守跳过。
    static func eventKey(shape: Shape, id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        switch shape {
        case .stepEnd: return "kimi-code:\(id)"
        case .statusUpdate: return "kimi:\(id)"
        }
    }

    // MARK: 时间桶

    /// 毫秒时间戳（Kimi Code `time`）→ UTC 半小时桶起点。
    static func bucketStart(fromMilliseconds ms: Double?) -> Date? {
        guard let ms, ms > 0 else { return nil }
        let seconds = ms / 1000
        return Date(timeIntervalSince1970: Double((Int(seconds) / 1800) * 1800))
    }

    /// 秒时间戳（旧版 `timestamp`，可含小数）→ UTC 半小时桶起点。
    static func bucketStart(fromSeconds seconds: Double?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double((Int(seconds) / 1800) * 1800))
    }

    // MARK: 模型名

    /// 模型别名清洗：剥离 `kimi-code/` 前缀（config.toml / config.update 的别名格式）。
    static func modelName(fromAlias alias: String?) -> String? {
        guard let alias, !alias.isEmpty else { return nil }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("kimi-code/") {
            let bare = String(trimmed.dropFirst("kimi-code/".count))
            return bare.isEmpty ? nil : bare
        }
        return trimmed
    }
}
