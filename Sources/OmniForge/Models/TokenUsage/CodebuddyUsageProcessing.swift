import Foundation

/// CodeBuddy transcript 解析归一化 — 语义完全复用共享的 Claude-fork 处理核心。
///
/// 去重 key 优先 `providerData.messageId`（同往返 function_call/message 共享）；
/// 默认模型从 `~/.codebuddy/settings.json` 的 `model` 字段读取（collector 侧）。
enum CodebuddyUsageProcessing {
    static let defaultModel = "codebuddy-unknown"
    static let options = ClaudeForkUsageProcessing.codebuddy

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
            provider: .codebuddy,
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