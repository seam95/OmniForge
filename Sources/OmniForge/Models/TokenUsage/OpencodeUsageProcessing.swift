import CryptoKit
import Foundation

// MARK: - opencode message 行（隐私红线：只声明身份/模型/用量字段）

/// opencode `message.data` JSON — 只声明身份/模型/时间/用量字段；消息正文不声明。
///
/// `tokens` 为消息级**累积值**（`cache.read/write` 与 input/output 分列）：
/// 采集侧按「每消息上次 totals 差分」求增量。
struct OpencodeMessageData: Decodable, Equatable {
    let id: String?
    let sessionID: String?
    let modelID: String?
    /// v1 字符串形态的 `model` 键；v2（opencode2）把同一键写成对象，由
    /// `nestedModel` 承载（两者互斥）。
    let model: String?
    let modelId: String?
    let providerID: String?
    let provider: String?
    let nestedModel: NestedModel?
    let time: Time?
    let tokens: Tokens?

    /// v2 嵌套模型对象：`model:{id,providerID}`。
    struct NestedModel: Decodable, Equatable {
        let id: String?
        let providerID: String?
    }

    struct Time: Decodable, Equatable {
        let created: Double?
        let completed: Double?

        enum CodingKeys: String, CodingKey {
            case created, completed
        }
    }

    struct Tokens: Decodable, Equatable {
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: Cache?

        struct Cache: Decodable, Equatable {
            let read: Int?
            let write: Int?
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionID = "sessionID", modelID = "modelID", model, modelId, providerID = "providerID"
        case provider, time, tokens
    }

    init(
        id: String? = nil,
        sessionID: String? = nil,
        modelID: String? = nil,
        model: String? = nil,
        modelId: String? = nil,
        providerID: String? = nil,
        provider: String? = nil,
        nestedModel: NestedModel? = nil,
        time: Time? = nil,
        tokens: Tokens? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.modelID = modelID
        self.model = model
        self.modelId = modelId
        self.providerID = providerID
        self.provider = provider
        self.nestedModel = nestedModel
        self.time = time
        self.tokens = tokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        time = try c.decodeIfPresent(Time.self, forKey: .time)
        tokens = try c.decodeIfPresent(Tokens.self, forKey: .tokens)
        if let object = try? c.decodeIfPresent(NestedModel.self, forKey: .model) {
            nestedModel = object
            model = nil
        } else {
            nestedModel = nil
            model = try c.decodeIfPresent(String.self, forKey: .model)
        }
    }

    /// 归一化模型 id：v1 扁平字段优先，v2 嵌套 `model.id` 兜底。
    var effectiveModelID: String? {
        modelID ?? model ?? modelId ?? nestedModel?.id
    }

    /// 归一化 provider：v1 顶层 `providerID`，v2 嵌套 `model.providerID`。
    var effectiveProviderID: String? {
        providerID ?? nestedModel?.providerID ?? provider
    }
}

// MARK: - 解析纯函数

/// opencode 行解析归一化 — 纯函数；六列映射 / 消息 key / 模型链 / 时间 / fork 指纹。
enum OpencodeUsageProcessing {
    static let defaultModel = "unknown"

    /// 六列映射（字段互斥，无减法）；全零 → nil。
    static func normalizedTotals(from tokens: OpencodeMessageData.Tokens?) -> TokenUsage? {
        guard let tokens else { return nil }
        let input = max(0, tokens.input ?? 0)
        let output = max(0, tokens.output ?? 0)
        let reasoning = max(0, tokens.reasoning ?? 0)
        let cached = max(0, tokens.cache?.read ?? 0)
        let cacheWrite = max(0, tokens.cache?.write ?? 0)
        let total = input + output + reasoning
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    /// 消息 key：`sessionID|messageID`（两者都必需）。
    static func messageKey(id: String?, sessionID: String?) -> String? {
        guard let id, !id.isEmpty, let sessionID, !sessionID.isEmpty else { return nil }
        return "\(sessionID)|\(id)"
    }

    /// 模型链：`modelID` → `model` → `modelId` → v2 嵌套 `model.id` → unknown。
    static func modelName(_ data: OpencodeMessageData) -> String {
        if let candidate = data.effectiveModelID,
           !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
        return defaultModel
    }

    /// 事件时间：`time.completed` → `time.created`（秒/毫秒自适应 → 毫秒）。
    static func timestampMs(_ data: OpencodeMessageData) -> Double? {
        let value = data.time?.completed ?? data.time?.created
        guard let value, value > 0, value.isFinite else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }

    // MARK: fork 复制指纹（issue #426 语义）

    /// 窄指纹：来源 + created/completed 毫秒 + 五列 token + 模型 + provider。
    /// 仅跨会话同指纹判定为 fork 复制（同会话内两次 turn 永不视为复制）。
    static func fingerprint(
        source: String,
        data: OpencodeMessageData,
        totals: TokenUsage
    ) -> String? {
        let created = epochMilliseconds(data.time?.created) ?? 0
        let completed = epochMilliseconds(data.time?.completed) ?? 0
        if created == 0 && completed == 0 { return nil }
        let model = modelName(data)
        let provider = data.effectiveProviderID ?? ""
        let raw = [
            source,
            String(created),
            String(completed),
            String(totals.inputTokens),
            String(totals.outputTokens),
            String(totals.cachedInputTokens),
            String(totals.cacheCreationInputTokens),
            String(totals.reasoningOutputTokens),
            model,
            provider,
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        let base64URL = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return String(base64URL.prefix(22))
    }

    private static func epochMilliseconds(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }
}