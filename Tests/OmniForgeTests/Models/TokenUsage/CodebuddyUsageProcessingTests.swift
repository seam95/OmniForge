import XCTest
@testable import OmniForge

/// CodeBuddy transcript 行解析：rawUsage 减法、缓存镜像取最大、reasoning 拆分、去重链。
final class CodebuddyUsageProcessingTests: XCTestCase {

    private func rawUsage(
        prompt: Int = 0,
        completion: Int = 0,
        cacheRead: Int? = nil,
        cachedTokens: Int? = nil,
        promptCacheHit: Int? = nil,
        cacheCreation: Int? = nil,
        promptCacheWrite: Int? = nil,
        reasoning: Int? = nil
    ) -> ClaudeForkTranscriptEntry.ProviderData.RawUsage {
        ClaudeForkTranscriptEntry.ProviderData.RawUsage(
            promptTokens: prompt,
            completionTokens: completion,
            cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            promptCacheHitTokens: promptCacheHit,
            promptCacheWriteTokens: promptCacheWrite,
            promptTokensDetails: ClaudeForkTranscriptEntry.ProviderData.RawUsage.Details(
                cachedTokens: cachedTokens,
                reasoningTokens: nil
            ),
            completionTokensDetails: ClaudeForkTranscriptEntry.ProviderData.RawUsage.Details(
                cachedTokens: nil,
                reasoningTokens: reasoning
            )
        )
    }

    // MARK: - 六列归一化

    func test_tokenUsage_subtractsCachedAndReasoning() {
        let usage = CodebuddyUsageProcessing.tokenUsage(
            from: rawUsage(
                prompt: 1000, completion: 300,
                cachedTokens: 200, cacheCreation: 50, reasoning: 30
            )
        )
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 750, "1000 - cached 200 - creation 50")
        XCTAssertEqual(usage?.cachedInputTokens, 200)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 50)
        XCTAssertEqual(usage?.outputTokens, 270, "300 - reasoning 30")
        XCTAssertEqual(usage?.reasoningOutputTokens, 30)
        XCTAssertEqual(usage?.totalTokens, 750 + 270 + 30, "缓存两列不计入总量")
    }

    func test_tokenUsage_cacheReadTakesMaxAcrossMirrors() {
        let usage = CodebuddyUsageProcessing.tokenUsage(
            from: rawUsage(prompt: 500, completion: 10, cacheRead: 100, cachedTokens: 200)
        )
        XCTAssertEqual(usage?.cachedInputTokens, 200, "镜像取最大（OpenAI cached_tokens 胜出）")
        XCTAssertEqual(usage?.inputTokens, 300)

        let deepseekMirror = CodebuddyUsageProcessing.tokenUsage(
            from: rawUsage(prompt: 500, completion: 10, cacheRead: 100, promptCacheHit: 250)
        )
        XCTAssertEqual(deepseekMirror?.cachedInputTokens, 250, "DeepSeek prompt_cache_hit_tokens 胜出")
    }

    func test_tokenUsage_codebuddyIncludesCacheWriteMirror() {
        let usage = CodebuddyUsageProcessing.tokenUsage(
            from: rawUsage(prompt: 300, completion: 5, cachedTokens: 100, promptCacheWrite: 40)
        )
        XCTAssertEqual(usage?.cacheCreationInputTokens, 40, "codebuddy 缓存写含 prompt_cache_write_tokens 镜像")
        XCTAssertEqual(usage?.inputTokens, 160, "300 - cached 100 - creation 40")
    }

    func test_tokenUsage_reasoningClampedToCompletion() {
        let usage = CodebuddyUsageProcessing.tokenUsage(
            from: rawUsage(prompt: 10, completion: 30, reasoning: 400)
        )
        XCTAssertEqual(usage?.reasoningOutputTokens, 30, "reasoning 不得超出 completion")
        XCTAssertEqual(usage?.outputTokens, 0)
    }

    func test_tokenUsage_nilWhenAllZero() {
        XCTAssertNil(CodebuddyUsageProcessing.tokenUsage(from: rawUsage()))
        XCTAssertNil(CodebuddyUsageProcessing.tokenUsage(from: nil))
    }

    // MARK: - 去重 key

    func test_dedupKey_prefersMessageId() {
        XCTAssertEqual(
            CodebuddyUsageProcessing.deduplicationKey(messageId: "m1", uuid: "u1", id: "i1", sessionId: "s1", timestampMs: 100),
            "codebuddy:m1"
        )
        XCTAssertEqual(
            CodebuddyUsageProcessing.deduplicationKey(messageId: nil, uuid: "u1", id: "i1", sessionId: "s1", timestampMs: 100),
            "codebuddy:u1"
        )
        XCTAssertEqual(
            CodebuddyUsageProcessing.deduplicationKey(messageId: nil, uuid: nil, id: "i1", sessionId: "s1", timestampMs: 100),
            "codebuddy:i1"
        )
        XCTAssertEqual(
            CodebuddyUsageProcessing.deduplicationKey(messageId: nil, uuid: nil, id: nil, sessionId: "s1", timestampMs: 100),
            "codebuddy:s1:100"
        )
        XCTAssertNil(
            CodebuddyUsageProcessing.deduplicationKey(messageId: nil, uuid: nil, id: nil, sessionId: nil, timestampMs: nil)
        )
    }

    // MARK: - 模型链

    func test_modelName_chain() {
        let provider = ClaudeForkTranscriptEntry.ProviderData(
            messageId: "m", model: "deepseek-v4", requestModelId: "req", rawUsage: nil
        )
        XCTAssertEqual(
            CodebuddyUsageProcessing.modelName(provider: provider, entryModel: "row-model", fallback: "fb"),
            "deepseek-v4"
        )
        XCTAssertEqual(
            CodebuddyUsageProcessing.modelName(provider: nil, entryModel: "row-model", fallback: "fb"),
            "row-model"
        )
        XCTAssertEqual(
            CodebuddyUsageProcessing.modelName(provider: nil, entryModel: nil, fallback: "fb"),
            "fb"
        )
    }

    // MARK: - 时间桶

    func test_bucketStart_roundsToHalfHour() {
        let start = CodebuddyUsageProcessing.bucketStart(fromMilliseconds: 1_784_502_600_000)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_784_502_000))
        XCTAssertNil(CodebuddyUsageProcessing.bucketStart(fromMilliseconds: nil))
    }
}