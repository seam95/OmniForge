import Foundation
import XCTest
@testable import OmniForge

/// DSH 事件解析：usage 优先级、reasoning 拆分、去重键、模型归属、fork 边界与桶时间。
final class DshUsageProcessingTests: XCTestCase {

    // MARK: - usage 映射

    func test_tokenUsage_splitsReasoningOutOfOutput() {
        let usage: [String: Any] = [
            "inputTokens": 100,
            "outputTokens": 40,
            "cacheReadTokens": 900,
            "cacheWriteTokens": 5,
            "reasoningTokens": 10,
        ]
        let tokens = DshUsageProcessing.tokenUsage(from: usage)
        XCTAssertEqual(tokens?.inputTokens, 100)
        XCTAssertEqual(tokens?.cachedInputTokens, 900)
        XCTAssertEqual(tokens?.cacheCreationInputTokens, 5)
        XCTAssertEqual(tokens?.outputTokens, 30, "output 必须拆出 reasoning")
        XCTAssertEqual(tokens?.reasoningOutputTokens, 10)
        XCTAssertEqual(tokens?.totalTokens, 140, "total 不含缓存读写")
    }

    func test_tokenUsage_zeroTotalsReturnsNil() {
        let usage: [String: Any] = [
            "inputTokens": 0,
            "outputTokens": 0,
            "cacheReadTokens": 100,
        ]
        XCTAssertNil(DshUsageProcessing.tokenUsage(from: usage), "只有缓存不产生计数")
    }

    // MARK: - 事件 → 入桶事件

    func test_usageEvent_messagePrefersTopLevelUsageOverStream() {
        let event = event(type: "assistant/message", seq: 10, time: 1_792_205_211_000, data: [
            "turn": 1,
            "step": 1,
            "message": [
                "id": "m-1",
                "source": ["provider": "deepseek-account", "model": "deepseek-v4.1-flash"],
            ],
            "usage": ["inputTokens": 50, "outputTokens": 10],
            "stream": [
                ["type": "chunk", "chunk": ["type": "usage", "usage": ["inputTokens": 999, "outputTokens": 999]]],
            ],
        ])
        let parsed = DshUsageProcessing.usageEvent(
            event,
            sessionID: "session-a",
            fallbackModel: nil,
            fallbackProvider: nil
        )
        XCTAssertEqual(parsed?.usage.inputTokens, 50)
        XCTAssertEqual(parsed?.usage.outputTokens, 10)
        XCTAssertEqual(parsed?.model, "deepseek-v4.1-flash")
        XCTAssertEqual(parsed?.provider, "deepseek-account")
    }

    func test_usageEvent_messageFallsBackToLastStreamUsage() {
        let event = event(type: "assistant/message", seq: 11, time: 1_792_205_212_000, data: [
            "turn": 1,
            "step": 2,
            "message": ["id": "m-2"],
            "stream": [
                ["type": "chunk", "chunk": ["type": "usage", "usage": ["inputTokens": 10, "outputTokens": 1]]],
                ["type": "chunk", "chunk": ["type": "usage", "usage": ["inputTokens": 20, "outputTokens": 5]]],
            ],
        ])
        let parsed = DshUsageProcessing.usageEvent(
            event,
            sessionID: "session-a",
            fallbackModel: "fallback-model",
            fallbackProvider: "fallback-provider"
        )
        XCTAssertEqual(parsed?.usage.inputTokens, 20, "取最后一个 usage chunk")
        XCTAssertEqual(parsed?.model, "fallback-model")
        XCTAssertEqual(parsed?.provider, "fallback-provider")
    }

    func test_usageEvent_attemptUsesStreamOnly() {
        let event = event(type: "assistant/attempt", seq: 12, time: 1_792_205_213_000, data: [
            "turn": 1,
            "step": 3,
            "attemptId": "attempt-1",
            "usage": ["inputTokens": 999, "outputTokens": 999],
            "stream": [
                ["type": "chunk", "chunk": ["type": "usage", "usage": ["inputTokens": 7, "outputTokens": 3]]],
            ],
        ])
        let parsed = DshUsageProcessing.usageEvent(
            event,
            sessionID: "session-a",
            fallbackModel: nil,
            fallbackProvider: nil
        )
        XCTAssertEqual(parsed?.usage.inputTokens, 7)
        XCTAssertEqual(parsed?.dedupKey.contains("attempt:attempt-id:attempt-1"), true)
    }

    func test_usageEvent_dedupKeyIsStableAndIncludesTokenSignature() {
        let event = event(type: "assistant/message", seq: 20, time: 1_792_205_214_000, data: [
            "message": ["id": "m-9", "source": ["provider": "p", "model": "model-a"]],
            "usage": ["inputTokens": 3, "outputTokens": 4, "cacheReadTokens": 5],
        ])
        let parsed = DshUsageProcessing.usageEvent(
            event,
            sessionID: "session-a",
            fallbackModel: nil,
            fallbackProvider: nil
        )
        XCTAssertEqual(
            parsed?.dedupKey,
            "dsh:msg:m-9:1792205214000:p:model-a:3:4:5:0:0"
        )
    }

    func test_usageEvent_servedResponseModelWinsOverConfiguredModel() {
        let event = event(type: "assistant/message", seq: 30, time: 1_792_205_215_000, data: [
            "message": [
                "id": "m-served",
                "source": [
                    "provider": "openrouter",
                    "model": "~x-ai/grok-latest",
                    "replayState": ["response": ["responseModel": "x-ai/grok-4.6"]],
                ],
            ],
            "usage": ["inputTokens": 10, "outputTokens": 2],
        ])
        let parsed = DshUsageProcessing.usageEvent(
            event,
            sessionID: "session-a",
            fallbackModel: nil,
            fallbackProvider: nil
        )
        XCTAssertEqual(parsed?.model, "x-ai/grok-4.6")
    }

    func test_usageEvent_missingTimeReturnsNil() {
        let event = event(type: "assistant/message", seq: 40, time: 0, data: [
            "message": ["id": "m-0"],
            "usage": ["inputTokens": 1, "outputTokens": 1],
        ])
        XCTAssertNil(DshUsageProcessing.usageEvent(
            event,
            sessionID: "session-a",
            fallbackModel: nil,
            fallbackProvider: nil
        ))
    }

    // MARK: - fork / 路由辅助

    func test_sessionHeader_readsSeedBoundary() {
        let header = event(type: "session", seq: 0, time: 0, data: [:])
        var withSeed = header
        withSeed["id"] = "session-a"
        withSeed["seedLength"] = 120
        withSeed["isSeeded"] = true
        let parsed = DshUsageProcessing.sessionHeader(withSeed)
        XCTAssertEqual(parsed?.id, "session-a")
        XCTAssertEqual(parsed?.seedLength, 120)
        XCTAssertEqual(parsed?.isSeeded, true)
    }

    func test_inheritedCut_onlyForTaggedEndSeed() {
        let tagged = event(type: "session/end-seed", seq: 42, time: 1, data: ["inherited": true])
        XCTAssertEqual(DshUsageProcessing.inheritedCut(tagged), 42)
        let untagged = event(type: "session/end-seed", seq: 43, time: 1, data: ["inherited": false])
        XCTAssertNil(DshUsageProcessing.inheritedCut(untagged))
    }

    func test_requestConfig_andStepSlotAndRetrySlot() {
        let header = event(type: "request/header", seq: 1, time: 1, data: [
            "header": ["config": ["provider": "deepseek-account", "model": "deepseek-v4.1-flash"]],
        ])
        let config = DshUsageProcessing.requestConfig(header)
        XCTAssertEqual(config?.provider, "deepseek-account")
        XCTAssertEqual(config?.model, "deepseek-v4.1-flash")

        let step = event(type: "step/start", seq: 2, time: 1, data: ["turn": 1, "step": 2])
        XCTAssertEqual(DshUsageProcessing.stepSlot(step)?.turn, 1)
        XCTAssertEqual(DshUsageProcessing.stepSlot(step)?.step, 2)

        let retry = event(type: "llm/retry-started", seq: 3, time: 1, data: ["turn": 1, "step": 2])
        XCTAssertEqual(DshUsageProcessing.retrySlot(retry)?.step, 2)
    }

    // MARK: - 桶时间

    func test_bucketStart_floorsToUtcHalfHour() {
        // 2026-10-22T13:59:00+08:00 = 05:59Z → 05:30Z 桶
        let date = DshUsageProcessing.bucketStart(fromMilliseconds: 1_792_653_540_000)
        XCTAssertNotNil(date)
        let seconds = date!.timeIntervalSince1970
        XCTAssertEqual(seconds.truncatingRemainder(dividingBy: 1800), 0)
    }

    // MARK: - 工具

    private func event(type: String, seq: Int, time: Int, data: [String: Any]) -> [String: Any] {
        ["type": type, "seq": seq, "time": time, "data": data]
    }
}
