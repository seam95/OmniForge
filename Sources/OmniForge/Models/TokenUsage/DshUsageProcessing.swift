import Foundation

// MARK: - DSH 事件解析（纯函数）

/// DSH 用量事件 — 从一行 wire 事件中提取的入桶所需字段。
struct DshUsageEvent: Equatable {
    var usage: TokenUsage
    /// 实际服务的模型（responseModel 优先）。
    var model: String
    /// 请求路由的 provider。
    var provider: String
    /// 跨扫描稳定去重键（写入 message_seen）。
    var dedupKey: String
    /// 事件时间（epoch 毫秒）。
    var timestampMs: Double
    /// 所属 turn（可能缺失）。
    var turn: Int64?
    /// 所属 step（可能缺失）。
    var step: Int64?
}

/// DSH 会话日志解析 — 只接触身份/用量/模型字段，正文永不物化。
///
/// 计费事件仅三类：assistant/message、assistant/attempt、compaction/summary。
/// - message 优先取 data.usage，缺失时取 data.stream 中最后一个 usage chunk；
/// - attempt 只取 stream 中最后一个 usage chunk；
/// - summary 取 data.usage。
enum DshUsageProcessing {
    static let defaultModel = "unknown"
    static let defaultProvider = "dsh"

    // MARK: 行解析

    /// JSON 行 → 字典；坏行返回 nil（逐行跳过，不影响整文件）。
    static func parseEvent(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    static func eventType(_ event: [String: Any]) -> String? {
        event["type"] as? String
    }

    static func seq(_ event: [String: Any]) -> Int64? {
        int64(event["seq"])
    }

    /// 事件顶层 time（epoch 毫秒）；缺失/非正数返回 nil。
    static func timeMs(_ event: [String: Any]) -> Double? {
        guard let value = double(event["time"]), value > 0 else { return nil }
        return value
    }

    // MARK: 会话头与路由

    /// session 头：id / seedLength / isSeeded（fork 复制边界）。
    static func sessionHeader(_ event: [String: Any]) -> (id: String?, seedLength: Int64, isSeeded: Bool)? {
        guard eventType(event) == "session" else { return nil }
        let id = nonEmpty(event["id"] as? String)
        let seedLength = max(0, int64(event["seedLength"]) ?? 0)
        let isSeeded = boolValue(event["isSeeded"])
        return (id, seedLength, isSeeded)
    }

    /// session/end-seed 且 data.inherited == true：返回该事件的 seq（fork 继承边界）。
    static func inheritedCut(_ event: [String: Any]) -> Int64? {
        guard eventType(event) == "session/end-seed" else { return nil }
        let data = event["data"] as? [String: Any]
        guard boolValue(data?["inherited"]) else { return nil }
        return seq(event)
    }

    /// request/header：路由 provider / model 兜底。
    static func requestConfig(_ event: [String: Any]) -> (provider: String?, model: String?)? {
        guard eventType(event) == "request/header",
              let data = event["data"] as? [String: Any],
              let header = data["header"] as? [String: Any],
              let config = header["config"] as? [String: Any] else {
            return nil
        }
        return (nonEmpty(config["provider"] as? String), nonEmpty(config["model"] as? String))
    }

    /// step/start：turn/step 槽位（用于 settlement 替换语义）。
    static func stepSlot(_ event: [String: Any]) -> (turn: Int64, step: Int64)? {
        guard eventType(event) == "step/start" else { return nil }
        return slot(from: event)
    }

    /// llm/retry-started：同一 (turn, step) 的重试开启新调用。
    static func retrySlot(_ event: [String: Any]) -> (turn: Int64, step: Int64)? {
        guard eventType(event) == "llm/retry-started" else { return nil }
        return slot(from: event)
    }

    static func isUserMessage(_ event: [String: Any]) -> Bool {
        eventType(event) == "user/message"
    }

    // MARK: 用量事件

    /// 三类计费事件 → 入桶事件；非计费事件/无用量/无有效时间返回 nil。
    ///
    /// - Parameters:
    ///   - sessionID: 会话 id（无 message.id 时构造去重键的兜底）。
    ///   - fallbackModel: 同文件最近的 request/header 模型。
    ///   - fallbackProvider: 同文件最近的 request/header provider。
    static func usageEvent(
        _ event: [String: Any],
        sessionID: String?,
        fallbackModel: String?,
        fallbackProvider: String?
    ) -> DshUsageEvent? {
        guard let type = eventType(event),
              ["assistant/message", "assistant/attempt", "compaction/summary"].contains(type),
              let data = event["data"] as? [String: Any],
              let usageDict = usageDictionary(from: data, eventType: type),
              let usage = tokenUsage(from: usageDict),
              let time = timeMs(event) else {
            return nil
        }

        let message = data["message"] as? [String: Any]
        let source = message?["source"] as? [String: Any]
        let model = servedModel(source: source) ?? fallbackModel ?? defaultModel
        let provider = nonEmpty(source?["provider"] as? String) ?? fallbackProvider ?? defaultProvider

        let kind: String
        switch type {
        case "compaction/summary": kind = "summary:"
        case "assistant/attempt": kind = "attempt:"
        default: kind = ""
        }
        let identity = deduplicationIdentity(
            event: event,
            type: type,
            data: data,
            message: message,
            sessionID: sessionID,
            timeMs: time
        )
        let key = "dsh:\(kind)\(identity):\(Int64(time)):\(provider):\(model):"
            + "\(usage.inputTokens):\(usage.outputTokens):\(usage.cachedInputTokens):"
            + "\(usage.cacheCreationInputTokens):\(usage.reasoningOutputTokens)"

        return DshUsageEvent(
            usage: usage,
            model: model,
            provider: provider,
            dedupKey: key,
            timestampMs: time,
            turn: int64(data["turn"]),
            step: int64(data["step"])
        )
    }

    /// UTC 半小时桶起点（epoch 毫秒 → 1800 秒对齐）。
    static func bucketStart(fromMilliseconds milliseconds: Double) -> Date? {
        guard milliseconds > 0, milliseconds.isFinite else { return nil }
        let seconds = milliseconds / 1000
        return Date(timeIntervalSince1970: (seconds / 1800).rounded(.down) * 1800)
    }

    // MARK: - 内部

    private static func slot(from event: [String: Any]) -> (turn: Int64, step: Int64)? {
        guard let data = event["data"] as? [String: Any],
              let turn = int64(data["turn"]),
              let step = int64(data["step"]) else {
            return nil
        }
        return (turn, step)
    }

    private static func usageDictionary(from data: [String: Any], eventType: String) -> [String: Any]? {
        switch eventType {
        case "assistant/message":
            if let usage = data["usage"] as? [String: Any] { return usage }
            return lastStreamUsage(data)
        case "assistant/attempt":
            return lastStreamUsage(data)
        case "compaction/summary":
            return data["usage"] as? [String: Any]
        default:
            return nil
        }
    }

    /// stream 数组中最后一个 usage chunk（中间快照不重复计）。
    private static func lastStreamUsage(_ data: [String: Any]) -> [String: Any]? {
        guard let stream = data["stream"] as? [[String: Any]] else { return nil }
        for record in stream.reversed() {
            guard (record["type"] as? String) == "chunk",
                  let chunk = record["chunk"] as? [String: Any],
                  (chunk["type"] as? String) == "usage",
                  let usage = chunk["usage"] as? [String: Any] else {
                continue
            }
            return usage
        }
        return nil
    }

    /// 六列归一化：output 拆出 reasoning（DSH 的 outputTokens 含 reasoning 子集）。
    static func tokenUsage(from usage: [String: Any]) -> TokenUsage? {
        let input = max(0, Int(clamping: int64(usage["inputTokens"]) ?? 0))
        let cached = max(0, Int(clamping: int64(usage["cacheReadTokens"]) ?? 0))
        let cacheCreation = max(0, Int(clamping: int64(usage["cacheWriteTokens"]) ?? 0))
        let reasoning = max(0, Int(clamping: int64(usage["reasoningTokens"]) ?? 0))
        let outputRaw = max(0, Int(clamping: int64(usage["outputTokens"]) ?? 0))
        let output = max(0, outputRaw - reasoning)
        let total = input + output + reasoning
        guard total > 0 else { return nil }
        return TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    /// 实际服务模型：replayState.response.responseModel → source.model。
    static func servedModel(source: [String: Any]?) -> String? {
        guard let source else { return nil }
        if let replay = source["replayState"] as? [String: Any],
           let response = replay["response"] as? [String: Any],
           let served = nonEmpty(response["responseModel"] as? String) {
            return served
        }
        return nonEmpty(source["model"] as? String)
    }

    /// 去重身份：按事件类型回退（message.id / attemptId / compactionId / seq / session）。
    private static func deduplicationIdentity(
        event: [String: Any],
        type: String,
        data: [String: Any],
        message: [String: Any]?,
        sessionID: String?,
        timeMs: Double
    ) -> String {
        let seqValue = seq(event)
        switch type {
        case "assistant/attempt":
            if let attemptID = nonEmpty(data["attemptId"] as? String) ?? nonEmpty(data["retryId"] as? String) {
                return "attempt-id:\(attemptID)"
            }
            if let seqValue { return "attempt-session:\(sessionID ?? ""):seq:\(seqValue)" }
            if let turn = int64(data["turn"]), let step = int64(data["step"]) {
                return "attempt-session:\(sessionID ?? ""):turn:\(turn):step:\(step):\(Int64(timeMs))"
            }
            return "attempt-session:\(sessionID ?? "")"
        case "compaction/summary":
            if let compactionID = nonEmpty(data["compactionId"] as? String) {
                return "cmp:\(compactionID)"
            }
            if let seqValue { return "seq:\(seqValue)" }
            return "sid:\(sessionID ?? "")"
        default:
            if let messageID = nonEmpty(message?["id"] as? String) {
                return "msg:\(messageID)"
            }
            if let seqValue { return "seq:\(seqValue)" }
            return "sid:\(sessionID ?? "")"
        }
    }

    /// JSONSerialization 的布尔是 NSNumber / Bool 混用，统一桥接。
    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["true", "1", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string)
        default: return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }
}
