import Foundation

/// WorkBuddy transcript 解析归一化 — JSONL 语义复用共享 Claude-fork 核心；
/// trace 摘要兜底（`~/.workbuddy/traces/**/trace_*.json`）在本文件解析。
enum WorkbuddyUsageProcessing {
    static let defaultModel = "auto"
    static let options = ClaudeForkUsageProcessing.workbuddy

    static func tokenUsage(
        from rawUsage: ClaudeForkTranscriptEntry.ProviderData.RawUsage?
    ) -> TokenUsage? {
        ClaudeForkUsageProcessing.tokenUsage(from: rawUsage, options: options)
    }

    static func modelName(
        provider: ClaudeForkTranscriptEntry.ProviderData?,
        entryModel: String?,
        fallback: String
    ) -> String {
        ClaudeForkUsageProcessing.modelName(
            provider: provider,
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
}

// MARK: - trace 摘要文档（隐私红线：只声明模型/用量/时间戳字段）

/// WorkBuddy trace 摘要 JSON — 无损兜底（会话 JSONL 无 rawUsage 时使用）。
/// 只声明身份/模型/用量/时间戳字段；执行步骤正文等永不解析。
struct WorkbuddyTraceDocument: Decodable, Equatable {
    let trace: Trace?

    struct Trace: Decodable, Equatable {
        let traceId: String?
        let sessionId: String?
        /// 毫秒或秒（自适应）。
        let startedAt: Double?
        let modelInfo: ModelInfo?
        let metadata: Metadata?

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

            enum CodingKeys: String, CodingKey {
                case sessionId = "sessionId"
                case startedAt = "startedAt"
                case modelInfo = "modelInfo"
            }
        }
    }
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