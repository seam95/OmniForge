import XCTest
@testable import OmniForge

/// trae-cn 会话行归一化 — 缓存拆分 / 半小时桶 / 坏行。
final class TraeCnUsageProcessingTests: XCTestCase {

    private func row(
        session: String? = "s1",
        model: String? = "doubao-1.5",
        usageTime: Double? = 1_784_502_000,
        input: Double? = 1000,
        output: Double? = 200,
        cacheRead: Double? = nil,
        cacheWrite: Double? = nil,
        extra: TraeCnSessionRow.ExtraInfo? = nil
    ) -> TraeCnSessionRow {
        TraeCnSessionRow(
            sessionId: session,
            modelName: model,
            usageTime: usageTime,
            inputToken: input,
            outputToken: output,
            cacheReadToken: cacheRead,
            cacheWriteToken: cacheWrite,
            extraInfo: extra
        )
    }

    func test_contribution_splitsCacheInclusiveInput() {
        let contribution = TraeCnUsageProcessing.contribution(
            from: row(input: 1000, output: 200, cacheRead: 300, cacheWrite: 40)
        )
        XCTAssertNotNil(contribution)
        XCTAssertEqual(contribution?.usage.inputTokens, 660, "1000 - cached 300 - write 40")
        XCTAssertEqual(contribution?.usage.cachedInputTokens, 300)
        XCTAssertEqual(contribution?.usage.cacheCreationInputTokens, 40)
        XCTAssertEqual(contribution?.usage.outputTokens, 200)
        XCTAssertEqual(contribution?.usage.totalTokens, 1200, "total = input + output（含缓存）")
        XCTAssertEqual(contribution?.model, "doubao-1.5")
    }

    func test_contribution_cacheFromExtraInfoWhenRowLacks() {
        let contribution = TraeCnUsageProcessing.contribution(
            from: row(input: 1000, output: 100, extra: .init(cacheReadToken: 200, cacheWriteToken: nil))
        )
        XCTAssertEqual(contribution?.usage.cachedInputTokens, 200)
        XCTAssertEqual(contribution?.usage.inputTokens, 800)
    }

    func test_contribution_cacheOptionalForModelsWithoutPromptCache() {
        let contribution = TraeCnUsageProcessing.contribution(from: row(input: 500, output: 50))
        XCTAssertEqual(contribution?.usage.cachedInputTokens, 0)
        XCTAssertEqual(contribution?.usage.inputTokens, 500)
    }

    func test_contribution_unknownModelAndBucketAlignment() {
        let contribution = TraeCnUsageProcessing.contribution(
            from: row(session: "s1", model: nil, usageTime: 1_784_502_600)
        )
        XCTAssertEqual(contribution?.model, "trae-cn-unknown")
        XCTAssertEqual(
            contribution?.bucketStart,
            Date(timeIntervalSince1970: 1_784_502_000),
            "usage_time 秒 → 半小时桶起点"
        )
    }

    func test_contribution_nilForBadRows() {
        XCTAssertNil(TraeCnUsageProcessing.contribution(from: row(session: nil)))
        XCTAssertNil(TraeCnUsageProcessing.contribution(from: row(usageTime: nil)))
        XCTAssertNil(TraeCnUsageProcessing.contribution(from: row(input: -1, output: 1)))
        XCTAssertNil(TraeCnUsageProcessing.contribution(from: row(input: 100.5, output: 1)))
    }

    func test_decoding_extraInfoAsString() throws {
        let json = """
        {"session_id":"s1","model_name":"doubao","usage_time":1784502000,"input_token":10,"output_token":2,\
        "extra_info":"{\\"cache_read_token\\":3}"}
        """
        let row = try JSONDecoder().decode(TraeCnSessionRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.extraInfo?.cacheReadToken, 3, "extra_info JSON 字符串解析")
    }
}