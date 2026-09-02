import Foundation

// MARK: - qoder 行字段（隐私红线：只声明身份/模型/用量字段）

/// qoder JOIN 行的 JSON 列解析（token_info / model_info / record_extra / preferred_model_info）。
enum QoderUsageProcessing {
    static let defaultModel = "qoder-agent"

    /// token_info JSON → 六列。`prompt_tokens` 已含 `cached_tokens` → 拆分；
    /// 非法/负值 → nil（参考 normalizeQoderTokens）。
    static func normalizedTotals(from tokenInfo: String?) -> TokenUsage? {
        guard let tokens = parseObject(tokenInfo) else { return nil }
        guard let prompt = finiteNumber(tokens["prompt_tokens"]),
              let completion = finiteNumber(tokens["completion_tokens"]) else {
            return nil
        }
        let cachedRaw = finiteNumber(tokens["cached_tokens"]) ?? 0
        guard prompt >= 0, cachedRaw >= 0, completion >= 0 else { return nil }
        let promptInt = Int(prompt)
        let cachedInt = min(promptInt, Int(cachedRaw))
        let output = Int(completion)
        let input = max(0, promptInt - cachedInt)
        let total = input + output
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cachedInt,
            cacheCreationInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: total
        )
    }

    /// 模型链：`model_info.model_key|modelKey` → `record_extra.modelConfig.key|model_config.key`
    /// → `preferred_model_info.model_key|modelKey|preferred_model|preferredModel` → 默认。
    static func modelName(
        modelInfo: String?,
        recordExtra: String?,
        preferredModelInfo: String?
    ) -> String {
        let modelInfoObject = parseObject(modelInfo)
        let recordExtraObject = parseObject(recordExtra)
        let preferredObject = parseObject(preferredModelInfo)
        let recordConfig = recordExtraObject?["modelConfig"] as? [String: Any]
            ?? recordExtraObject?["model_config"] as? [String: Any]
        let candidates = [
            modelInfoObject?["model_key"] as? String,
            modelInfoObject?["modelKey"] as? String,
            recordConfig?["key"] as? String,
            preferredObject?["model_key"] as? String,
            preferredObject?["modelKey"] as? String,
            preferredObject?["preferred_model"] as? String,
            preferredObject?["preferredModel"] as? String,
        ]
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return defaultModel
    }

    /// 消息 key：`session_id|id` → `id` → `row:<rowid>`。
    static func messageKey(id: String?, sessionID: String?, rowID: Int64?) -> String? {
        if let id, !id.isEmpty, let sessionID, !sessionID.isEmpty {
            return "\(sessionID)|\(id)"
        }
        if let id, !id.isEmpty {
            return id
        }
        if let rowID {
            return "row:\(rowID)"
        }
        return nil
    }

    /// 请求级归属 key：`request_id` → `session_id` → 消息 key。
    static func requestKey(requestID: String?, sessionID: String?, messageKey: String) -> String {
        if let requestID, !requestID.isEmpty { return requestID }
        if let sessionID, !sessionID.isEmpty { return sessionID }
        return messageKey
    }

    // MARK: - 工具

    /// JSON 字符串（或对象）→ 字典；nil/坏 JSON → nil。
    static func parseObject(_ value: String?) -> [String: Any]? {
        guard let value, !value.isEmpty else { return nil }
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number.doubleValue : nil
        case let string as String:
            return Double(string).flatMap { $0.isFinite ? $0 : nil }
        default:
            return nil
        }
    }
}