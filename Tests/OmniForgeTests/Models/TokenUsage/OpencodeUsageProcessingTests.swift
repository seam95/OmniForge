import XCTest
@testable import OmniForge

/// opencode message 行解析 — 六列映射 / 消息 key / 模型链 / 时间 / fork 指纹。
final class OpencodeUsageProcessingTests: XCTestCase {

    private func data(
        id: String? = "m1",
        sessionID: String? = "s1",
        modelID: String? = "deepseek-v4",
        providerID: String? = "opencode",
        created: Double? = 1_784_502_000_000,
        completed: Double? = 1_784_502_600_000,
        input: Int? = 100,
        output: Int? = 20,
        reasoning: Int? = 5,
        cacheRead: Int? = 10,
        cacheWrite: Int? = 3
    ) -> OpencodeMessageData {
        OpencodeMessageData(
            id: id,
            sessionID: sessionID,
            modelID: modelID,
            model: nil,
            modelId: nil,
            providerID: providerID,
            provider: nil,
            time: OpencodeMessageData.Time(created: created, completed: completed),
            tokens: OpencodeMessageData.Tokens(
                input: input,
                output: output,
                reasoning: reasoning,
                cache: OpencodeMessageData.Tokens.Cache(read: cacheRead, write: cacheWrite)
            )
        )
    }

    // MARK: - 六列

    func test_normalizedTotals_mapsDisjointColumns() {
        let totals = OpencodeUsageProcessing.normalizedTotals(from: data().tokens)
        XCTAssertEqual(totals?.inputTokens, 100)
        XCTAssertEqual(totals?.cachedInputTokens, 10)
        XCTAssertEqual(totals?.cacheCreationInputTokens, 3)
        XCTAssertEqual(totals?.outputTokens, 20)
        XCTAssertEqual(totals?.reasoningOutputTokens, 5)
        XCTAssertEqual(totals?.totalTokens, 125, "缓存两列不计入总量")
    }

    func test_normalizedTotals_nilWhenAllZero() {
        XCTAssertNil(OpencodeUsageProcessing.normalizedTotals(
            from: OpencodeMessageData.Tokens(input: 0, output: 0, reasoning: 0, cache: .init(read: 0, write: 0))
        ))
        XCTAssertNil(OpencodeUsageProcessing.normalizedTotals(from: nil))
    }

    // MARK: - key / 模型 / 时间

    func test_messageKey_requiresBothParts() {
        XCTAssertEqual(OpencodeUsageProcessing.messageKey(id: "m1", sessionID: "s1"), "s1|m1")
        XCTAssertNil(OpencodeUsageProcessing.messageKey(id: nil, sessionID: "s1"))
        XCTAssertNil(OpencodeUsageProcessing.messageKey(id: "m1", sessionID: nil))
    }

    func test_modelName_chain() {
        XCTAssertEqual(OpencodeUsageProcessing.modelName(data()), "deepseek-v4")
        XCTAssertEqual(OpencodeUsageProcessing.modelName(data(modelID: nil)), "unknown")
    }

    func test_timestampMs_prefersCompleted_adaptsSeconds() {
        XCTAssertEqual(OpencodeUsageProcessing.timestampMs(data()), 1_784_502_600_000)
        XCTAssertEqual(OpencodeUsageProcessing.timestampMs(data(completed: nil)), 1_784_502_000_000)
        XCTAssertEqual(OpencodeUsageProcessing.timestampMs(data(created: 1_784_502_000, completed: 1_784_502_600)), 1_784_502_600_000)
        XCTAssertNil(OpencodeUsageProcessing.timestampMs(data(created: nil, completed: nil)))
    }

    // MARK: - fork 指纹

    func test_fingerprint_deterministicAndSensitiveToSessionFields() {
        let a = data()
        let b = data(id: "other-id", sessionID: "other-session") // fork 复制：identity 变了
        let fpA = OpencodeUsageProcessing.fingerprint(source: "opencode", data: a, totals: OpencodeUsageProcessing.normalizedTotals(from: a.tokens)!)
        let fpB = OpencodeUsageProcessing.fingerprint(source: "opencode", data: b, totals: OpencodeUsageProcessing.normalizedTotals(from: b.tokens)!)
        XCTAssertEqual(fpA, fpB, "fork 复制只改 id/session → 指纹相同")
        XCTAssertEqual(fpA, OpencodeUsageProcessing.fingerprint(source: "opencode", data: a, totals: OpencodeUsageProcessing.normalizedTotals(from: a.tokens)!), "确定性")
    }

    func test_fingerprint_differentTotalsDifferentFingerprint() {
        let a = data(input: 100)
        let b = data(input: 999)
        let fpA = OpencodeUsageProcessing.fingerprint(source: "opencode", data: a, totals: OpencodeUsageProcessing.normalizedTotals(from: a.tokens)!)
        let fpB = OpencodeUsageProcessing.fingerprint(source: "opencode", data: b, totals: OpencodeUsageProcessing.normalizedTotals(from: b.tokens)!)
        XCTAssertNotEqual(fpA, fpB)
    }

    func test_fingerprint_sourceScoped() {
        let a = data()
        let totals = OpencodeUsageProcessing.normalizedTotals(from: a.tokens)!
        XCTAssertNotEqual(
            OpencodeUsageProcessing.fingerprint(source: "opencode", data: a, totals: totals),
            OpencodeUsageProcessing.fingerprint(source: "zcode", data: a, totals: totals)
        )
    }
}