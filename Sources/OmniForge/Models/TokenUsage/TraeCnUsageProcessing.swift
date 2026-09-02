import Foundation

// MARK: - trae-cn 会话行（隐私红线：只声明用量/模型字段）

/// TRAE CN 用量 API 单行会话 — 只声明用量/模型字段。
///
/// 语义：
/// - `input_token` 为**含缓存**的口径 → 拆出 cache_read / cache_write 后余量为纯输入；
/// - 缓存字段对无 prompt-cache 概念的模型可缺省（视为 0）；
/// - `usage_time` 为 epoch 秒；半小时桶按其对齐。
struct TraeCnSessionRow: Decodable, Equatable {
    let sessionId: String?
    let modelName: String?
    /// epoch 秒。
    let usageTime: Double?
    let inputToken: Double?
    let outputToken: Double?
    let cacheReadToken: Double?
    let cacheWriteToken: Double?
    let extraInfo: ExtraInfo?

    struct ExtraInfo: Decodable, Equatable {
        let cacheReadToken: Double?
        let cacheWriteToken: Double?

        enum CodingKeys: String, CodingKey {
            case cacheReadToken = "cache_read_token"
            case cacheWriteToken = "cache_write_token"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case modelName = "model_name"
        case usageTime = "usage_time"
        case inputToken = "input_token"
        case outputToken = "output_token"
        case cacheReadToken = "cache_read_token"
        case cacheWriteToken = "cache_write_token"
        case extraInfo = "extra_info"
    }

    /// extra_info 可能是对象或 JSON 字符串（traeCnExtraInfo 语义）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        usageTime = try container.decodeIfPresent(Double.self, forKey: .usageTime)
        inputToken = try container.decodeIfPresent(Double.self, forKey: .inputToken)
        outputToken = try container.decodeIfPresent(Double.self, forKey: .outputToken)
        if let extra = try? container.decodeIfPresent(ExtraInfo.self, forKey: .extraInfo) {
            extraInfo = extra
        } else if let extraString = try container.decodeIfPresent(String.self, forKey: .extraInfo),
                  let data = extraString.data(using: .utf8) {
            extraInfo = try? JSONDecoder().decode(ExtraInfo.self, from: data)
        } else {
            extraInfo = nil
        }
        cacheReadToken = try container.decodeIfPresent(Double.self, forKey: .cacheReadToken)
        cacheWriteToken = try container.decodeIfPresent(Double.self, forKey: .cacheWriteToken)
    }

    /// 测试/纯函数便捷构造。
    init(
        sessionId: String?,
        modelName: String?,
        usageTime: Double?,
        inputToken: Double?,
        outputToken: Double?,
        cacheReadToken: Double?,
        cacheWriteToken: Double?,
        extraInfo: ExtraInfo?
    ) {
        self.sessionId = sessionId
        self.modelName = modelName
        self.usageTime = usageTime
        self.inputToken = inputToken
        self.outputToken = outputToken
        self.cacheReadToken = cacheReadToken
        self.cacheWriteToken = cacheWriteToken
        self.extraInfo = extraInfo
    }
}

// MARK: - 解析纯函数

/// trae-cn 会话行归一化 — 纯函数；缓存拆分 / 半小时桶 / 未知模型。
enum TraeCnUsageProcessing {
    static let unknownModel = "trae-cn-unknown"

    /// 归一化结果。
    struct Contribution: Equatable {
        var model: String
        var bucketStart: Date
        var usage: TokenUsage
    }

    /// 行 → 贡献；坏行（缺 session_id / 非整秒 / 负数 token）→ nil。
    static func contribution(from row: TraeCnSessionRow) -> Contribution? {
        guard let sessionID = row.sessionId, !sessionID.isEmpty else { return nil }
        guard let usageTime = row.usageTime, usageTime > 0 else { return nil }
        guard let bucketStart = bucketStart(fromSeconds: usageTime) else { return nil }
        guard let inputRaw = safeInteger(row.inputToken),
              let output = safeInteger(row.outputToken) else {
            return nil
        }
        let cacheRead = safeInteger(row.cacheReadToken ?? row.extraInfo?.cacheReadToken) ?? 0
        let cacheWrite = safeInteger(row.cacheWriteToken ?? row.extraInfo?.cacheWriteToken) ?? 0
        guard inputRaw >= 0, output >= 0, cacheRead >= 0, cacheWrite >= 0 else { return nil }

        let cachedInput = min(inputRaw, cacheRead)
        let cacheCreation = min(inputRaw - cachedInput, cacheWrite)
        let input = inputRaw - cachedInput - cacheCreation
        let total = input + output
        let model = (row.modelName?.isEmpty == false ? row.modelName! : unknownModel)
        let usage = TokenUsage(
            inputTokens: input,
            cachedInputTokens: cachedInput,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: output,
            reasoningOutputTokens: 0,
            totalTokens: total
        )
        return Contribution(model: model, bucketStart: bucketStart, usage: usage)
    }

    /// 秒时间戳 → UTC 半小时桶起点。
    static func bucketStart(fromSeconds seconds: Double?) -> Date? {
        guard let seconds, seconds > 0, seconds.isFinite else { return nil }
        let intSeconds = Int(seconds)
        return Date(timeIntervalSince1970: Double((intSeconds / 1800) * 1800))
    }

    /// 毫秒时间戳 → 半小时桶起点（窗口对齐用）。
    static func bucketStart(fromMilliseconds ms: Double) -> Date {
        let seconds = Int(ms / 1000)
        return Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
    }

    /// 安全整数（API 返回 JSON 数字；非法/负值 → nil）。
    private static func safeInteger(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value == value.rounded() else { return nil }
        return Int(value)
    }
}