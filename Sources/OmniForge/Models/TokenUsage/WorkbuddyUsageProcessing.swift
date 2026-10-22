import Foundation

/// WorkBuddy transcript 解析归一化 — JSONL 语义复用共享 Claude-fork 核心；
/// trace 摘要兜底（`~/.workbuddy/traces/**/trace_*.json`）在本文件解析。
///
/// 恢复说明（2026-10-22）：ed6dada 移除了 `ClaudeForkUsageProcessing.workbuddy`
/// 选项（includeCacheWriteMirror: false + includeRequestModelId: true）。当前共享核心只剩
/// `.codebuddy`。WorkBuddy 与 CodeBuddy 同为 Claude-fork，rawUsage 字段语义一致；
/// 本机真实数据中 `cache_creation_input_tokens` 与 `prompt_cache_write_tokens` 恒等，
/// 因此缓存写取最大值的 `.codebuddy` 配置与旧行为等价。
/// `requestModelId` 模型链优先级收在本文件实现，不修改 ClaudeForkUsageProcessing。
enum WorkbuddyUsageProcessing {
    static let defaultModel = "auto"
    static let options = ClaudeForkUsageProcessing.codebuddy

    static func tokenUsage(
        from rawUsage: ClaudeForkTranscriptEntry.ProviderData.RawUsage?
    ) -> TokenUsage? {
        ClaudeForkUsageProcessing.tokenUsage(from: rawUsage, options: options)
    }

    /// 模型链（旧 WorkBuddy 语义）：
    /// `providerData.model` → `providerData.requestModelId` → 行级 `model` → 回退。
    static func modelName(
        provider: ClaudeForkTranscriptEntry.ProviderData?,
        entryModel: String?,
        fallback: String
    ) -> String {
        if let model = provider?.model, !isBlank(model) {
            return model
        }
        if let request = provider?.requestModelId, !isBlank(request) {
            return request
        }
        return ClaudeForkUsageProcessing.modelName(
            provider: nil,
            entryModel: entryModel,
            fallback: fallback,
            options: options
        )
    }

    static func deduplicationKey(
        messageId: String?,
        uuid: String?,
        id: String?,
        sessionId: String?,
        timestampMs: Double?
    ) -> String? {
        ClaudeForkUsageProcessing.deduplicationKey(
            provider: .workbuddy,
            messageId: messageId,
            uuid: uuid,
            id: id,
            sessionId: sessionId,
            timestampMs: timestampMs
        )
    }

    static func bucketStart(fromMilliseconds ms: Double?) -> Date? {
        ClaudeForkUsageProcessing.bucketStart(fromMilliseconds: ms)
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - trace 摘要文档（隐私红线：只声明模型/用量/时间戳字段）

/// WorkBuddy trace 摘要 JSON — 无损兜底（会话 JSONL 无 rawUsage 时使用）。
/// 只声明身份/模型/用量/时间戳字段；执行步骤正文等永不解析。
struct WorkbuddyTraceDocument: Decodable, Equatable {
    let trace: Trace?

    struct Trace: Decodable, Equatable {
        let traceId: String?
        let sessionId: String?
        /// epoch 毫秒或秒（自适应）。
        /// 兼容数字与 ISO8601 字符串：本机真实 trace 使用字符串（如 2026-09-23T06:06:19.706Z）。
        let startedAt: Double?
        let modelInfo: ModelInfo?
        let metadata: Metadata?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            traceId = try container.decodeIfPresent(String.self, forKey: .traceId)
            sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
            startedAt = TraceTimestamp.decode(container, forKey: .startedAt)
            modelInfo = try container.decodeIfPresent(ModelInfo.self, forKey: .modelInfo)
            metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
        }

        enum CodingKeys: String, CodingKey {
            case traceId
            case sessionId
            case startedAt
            case modelInfo
            case metadata
        }

        struct ModelInfo: Decodable, Equatable {
            let totalInputTokens: Int?
            let totalOutputTokens: Int?
            let totalCachedTokens: Int?
            let models: [String]?
            let model: String?

            enum CodingKeys: String, CodingKey {
                case totalInputTokens = "totalInputTokens"
                case totalOutputTokens = "totalOutputTokens"
                case totalCachedTokens = "totalCachedTokens"
                case models
                case model
            }
        }

        struct Metadata: Decodable, Equatable {
            let sessionId: String?
            let startedAt: Double?
            let modelInfo: ModelInfo?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
                startedAt = TraceTimestamp.decode(container, forKey: .startedAt)
                modelInfo = try container.decodeIfPresent(ModelInfo.self, forKey: .modelInfo)
            }

            enum CodingKeys: String, CodingKey {
                case sessionId
                case startedAt
                case modelInfo
            }
        }
    }
}

// MARK: - 时间字段兼容解码

/// trace 时间字段兼容解码：数字（毫秒/秒自适应）或 ISO8601 字符串。
private enum TraceTimestamp {
    static func decode<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Double? {
        if let number = try? container.decode(Double.self, forKey: key) {
            return number
        }
        if let string = try? container.decode(String.self, forKey: key) {
            return milliseconds(from: string)
        }
        return nil
    }

    /// ISO8601 字符串 → epoch 毫秒；纯数字字符串按数字返回（秒/毫秒由调用方自适应）。
    private static func milliseconds(from string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = Double(trimmed) {
            return number
        }
        guard let date = isoFractional.date(from: trimmed) ?? isoPlain.date(from: trimmed) else {
            return nil
        }
        return date.timeIntervalSince1970 * 1000
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()
}

// MARK: - trace 解析纯函数

extension WorkbuddyUsageProcessing {
    /// 一次 trace 估算的结果。
    struct TraceUsage: Equatable {
        var traceId: String
        var sessionId: String
        var model: String
        var usage: TokenUsage
        /// epoch 毫秒。
        var timestampMs: Double
    }

    /// trace 文档 → 估算（模型链 models[0] → model → fallback；cached 拆分）。
    /// 无 traceId / 时间戳 / 正总量 → nil。
    static func traceUsage(
        from document: WorkbuddyTraceDocument?,
        fallbackModel: String,
        fileURL: URL
    ) -> TraceUsage? {
        guard let trace = document?.trace else { return nil }
        let traceId = (trace.traceId?.isEmpty == false ? trace.traceId : nil)
            ?? fileURL.deletingPathExtension().lastPathComponent
        guard !traceId.isEmpty else { return nil }
        let metadata = trace.metadata
        let modelInfo = trace.modelInfo ?? metadata?.modelInfo
        let sessionId = (trace.sessionId?.isEmpty == false ? trace.sessionId : nil)
            ?? (metadata?.sessionId?.isEmpty == false ? metadata?.sessionId : nil)
            ?? traceId

        let startedAt = trace.startedAt ?? metadata?.startedAt
        let timestampMs: Double?
        if let startedAt, startedAt > 0 {
            timestampMs = startedAt > 10_000_000_000 ? startedAt : startedAt * 1000
        } else {
            timestampMs = nil
        }
        guard let timestampMs, timestampMs > 0 else { return nil }

        let totalInput = max(0, modelInfo?.totalInputTokens ?? 0)
        let totalOutput = max(0, modelInfo?.totalOutputTokens ?? 0)
        let totalCached = min(totalInput, max(0, modelInfo?.totalCachedTokens ?? 0))
        guard totalInput + totalOutput > 0 else { return nil }

        let model = modelInfo?.models?.first
            ?? modelInfo?.model
            ?? fallbackModel
        let input = max(0, totalInput - totalCached)
        let usage = TokenUsage(
            inputTokens: input,
            cachedInputTokens: totalCached,
            cacheCreationInputTokens: 0,
            outputTokens: totalOutput,
            reasoningOutputTokens: 0,
            totalTokens: input + totalOutput
        )
        return TraceUsage(
            traceId: traceId,
            sessionId: sessionId,
            model: model,
            usage: usage,
            timestampMs: timestampMs
        )
    }
}
