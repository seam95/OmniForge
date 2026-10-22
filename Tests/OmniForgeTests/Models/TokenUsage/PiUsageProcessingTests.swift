import Foundation
import XCTest
@testable import OmniForge

/// Pi / Oh My Pi 行解析归一化 — 纯函数：两种记录形状（Pi modelId / OMP model）、
/// 六列映射（reasoning 从 output 拆出）、去重 key、路径会话 id、半小时桶。
final class PiUsageProcessingTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func record(_ line: String) -> PiSessionRecord? {
        PiUsageProcessing.record(from: line, decoder: decoder)
    }

    // MARK: - 行解码

    func test_record_decodesPiSessionHeaderAndMessage() throws {
        let header = try XCTUnwrap(record(#"{"type":"session","version":3,"id":"01a161a6-d655-7217-90e9-911de238f142","timestamp":"2026-10-22T03:28:06.230Z","cwd":"/tmp/proj"}"#));
        XCTAssertEqual(header.type, "session")
        XCTAssertEqual(PiUsageProcessing.sessionID(from: header), "01a161a6-d655-7217-90e9-911de238f142")

        let message = try XCTUnwrap(record(#"{"type":"message","id":"50850f5b","timestamp":"2026-10-22T03:28:13.641Z","message":{"role":"assistant","content":[{"type":"text","text":"usage 正文不应被解析"}],"model":"deepseek-v4.1-flash","provider":"opencode-go","usage":{"input":1000,"output":100,"cacheRead":200,"cacheWrite":50,"reasoning":40,"totalTokens":1350}}}"#));
        XCTAssertEqual(message.id, "50850f5b")
        XCTAssertEqual(message.message?.role, "assistant")
        XCTAssertEqual(message.message?.model, "deepseek-v4.1-flash")
        XCTAssertEqual(message.message?.usage?.input, 1000)
        XCTAssertEqual(message.message?.usage?.reasoning, 40)
    }

    func test_record_acceptsBOMAndRejectsBlankOrMalformedLines() {
        let bomLine = "\u{FEFF}" + #"{"type":"session","id":"s1"}"#
        XCTAssertEqual(record(bomLine)?.type, "session", "首行 BOM 不应破坏解码")
        XCTAssertNil(record(""))
        XCTAssertNil(record("   "))
        XCTAssertNil(record("not json"))
        XCTAssertNil(record("[1,2,3]"))
        XCTAssertNil(record(#"{"type":"message""#), "半行 JSON 跳过")
    }

    func test_record_ompMessageDecodesReasoningTokensSpelling() throws {
        let message = try XCTUnwrap(record(#"{"type":"message","id":"m1","message":{"role":"assistant","model":"deepseek-v4-flash","usage":{"input":100,"output":50,"cacheRead":10,"cacheWrite":5,"reasoningTokens":20,"totalTokens":165}}}"#));
        XCTAssertEqual(message.message?.usage?.reasoningTokens, 20)
        XCTAssertNil(message.message?.usage?.reasoning)
    }

    // MARK: - 模型归属

    func test_modelChange_piUsesModelIdAndProvider() throws {
        let line = #"{"type":"model_change","id":"d63103f4","parentId":null,"timestamp":"2026-10-22T03:28:06.253Z","provider":"opencode-go","modelId":"deepseek-v4.1-flash"}"#
        let change = try XCTUnwrap(PiUsageProcessing.modelChange(from: try XCTUnwrap(record(line))));
        XCTAssertEqual(change.model, "deepseek-v4.1-flash")
        XCTAssertEqual(change.provider, "opencode-go")
    }

    func test_modelChange_ompUsesModelKeyAndNilProvider() throws {
        let line = #"{"type":"model_change","id":"1b59559c","parentId":null,"timestamp":"2026-07-09T02:08:43.818Z","model":"deepseek/deepseek-v4-flash"}"#
        let change = try XCTUnwrap(PiUsageProcessing.modelChange(from: try XCTUnwrap(record(line))));
        XCTAssertEqual(change.model, "deepseek/deepseek-v4-flash")
        XCTAssertNil(change.provider)
    }

    func test_modelChange_prefersModelIdAndRejectsBlankOrOtherTypes() throws {
        let both = try XCTUnwrap(record(#"{"type":"model_change","modelId":"model-id","model":"model-fallback"}"#));
        XCTAssertEqual(PiUsageProcessing.modelChange(from: both)?.model, "model-id")

        let blank = try XCTUnwrap(record(#"{"type":"model_change","modelId":"   ","model":""}"#));
        XCTAssertNil(PiUsageProcessing.modelChange(from: blank))

        let message = try XCTUnwrap(record(#"{"type":"message","id":"m1"}"#));
        XCTAssertNil(PiUsageProcessing.modelChange(from: message), "非 model_change 行不产出模型")
    }

    func test_messageModel_trimsAndFallsBackToNil() throws {
        let message = try XCTUnwrap(record(#"{"type":"message","message":{"role":"assistant","model":"  gpt-5  "}}"#));
        XCTAssertEqual(PiUsageProcessing.messageModel(from: message.message), "gpt-5")
        let blank = try XCTUnwrap(record(#"{"type":"message","message":{"role":"assistant","model":" "}}"#));
        XCTAssertNil(PiUsageProcessing.messageModel(from: blank.message))
    }

    // MARK: - 六列映射

    func test_tokenUsage_mapsSixColumnsAndSplitsReasoningFromOutput() {
        let usage = PiTokenUsage(
            input: 1000, output: 100, cacheRead: 200, cacheWrite: 50, reasoning: 40, reasoningTokens: nil
        )
        let normalized = PiUsageProcessing.tokenUsage(from: usage)
        XCTAssertEqual(normalized?.inputTokens, 1000)
        XCTAssertEqual(normalized?.cachedInputTokens, 200, "cached = cacheRead")
        XCTAssertEqual(normalized?.cacheCreationInputTokens, 50, "cacheCreation = cacheWrite")
        XCTAssertEqual(normalized?.outputTokens, 60, "output 拆出 reasoning 子集：100 - 40")
        XCTAssertEqual(normalized?.reasoningOutputTokens, 40)
        XCTAssertEqual(normalized?.totalTokens, 1100, "total = input + output + reasoning，缓存不计入")
    }

    func test_tokenUsage_ompReasoningTokensIsSubsetOfOutput() {
        let usage = PiTokenUsage(input: 100, output: 50, cacheRead: 10, cacheWrite: 5, reasoning: nil, reasoningTokens: 20)
        let normalized = PiUsageProcessing.tokenUsage(from: usage)
        XCTAssertEqual(normalized?.reasoningOutputTokens, 20, "OMP 拼写 reasoningTokens")
        XCTAssertEqual(normalized?.outputTokens, 30)
        XCTAssertEqual(normalized?.totalTokens, 150, "total = 100 + 30 + 20")
        XCTAssertEqual(normalized?.cachedInputTokens, 10)
        XCTAssertEqual(normalized?.cacheCreationInputTokens, 5)
    }

    func test_tokenUsage_withoutReasoningKeepsOutput() {
        let usage = PiTokenUsage(input: 100, output: 50, cacheRead: nil, cacheWrite: nil, reasoning: nil, reasoningTokens: nil)
        let normalized = PiUsageProcessing.tokenUsage(from: usage)
        XCTAssertEqual(normalized?.outputTokens, 50)
        XCTAssertEqual(normalized?.reasoningOutputTokens, 0)
        XCTAssertEqual(normalized?.totalTokens, 150)
    }

    func test_tokenUsage_cachesDoNotCountTowardTotal() {
        let usage = PiTokenUsage(input: 10, output: 5, cacheRead: 1000, cacheWrite: 500, reasoning: nil, reasoningTokens: nil)
        XCTAssertEqual(PiUsageProcessing.tokenUsage(from: usage)?.totalTokens, 15)
    }

    func test_tokenUsage_zeroOrNilReturnsNilAndNegativesAreClamped() {
        XCTAssertNil(PiUsageProcessing.tokenUsage(from: nil))
        XCTAssertNil(PiUsageProcessing.tokenUsage(from: PiTokenUsage(
            input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: nil, reasoningTokens: nil
        )))
        let clamped = PiUsageProcessing.tokenUsage(from: PiTokenUsage(
            input: -5, output: 10, cacheRead: -1, cacheWrite: -1, reasoning: 30, reasoningTokens: nil
        ))
        XCTAssertEqual(clamped?.inputTokens, 0)
        XCTAssertEqual(clamped?.cachedInputTokens, 0)
        XCTAssertEqual(clamped?.outputTokens, 0, "reasoning 大于 output 时 output 归零")
        XCTAssertEqual(clamped?.reasoningOutputTokens, 30)
        XCTAssertEqual(clamped?.totalTokens, 30)
    }

    // MARK: - 去重 key

    func test_deduplicationKey_usesMessageIDThenRowFallback() {
        XCTAssertEqual(
            PiUsageProcessing.deduplicationKey(namespace: "pi", sessionID: "sess", messageID: "m1", lineNumber: 9),
            "pi:sess:m1"
        )
        XCTAssertEqual(
            PiUsageProcessing.deduplicationKey(namespace: "pi", sessionID: "sess", messageID: nil, lineNumber: 9),
            "pi:sess:line:9", "无 message.id 的旧记录用行号兜底"
        )
        XCTAssertEqual(
            PiUsageProcessing.deduplicationKey(namespace: "omp", sessionID: nil, messageID: " ", lineNumber: 3),
            "omp:unknown:line:3", "空 id 等同于缺失")
    }

    func test_sessionMarkerKey_isPathBasedAndNamespaced() {
        XCTAssertEqual(
            PiUsageProcessing.sessionMarkerKey(namespace: "omp", filePath: "/tmp/a.jsonl"),
            "omp:session-file:/tmp/a.jsonl"
        )
    }

    // MARK: - 时间桶

    func test_bucketStart_isoTimestampAlignsToUtcHalfHour() throws {
        let iso = "2026-10-22T03:28:06.230Z"
        let start = try XCTUnwrap(PiUsageProcessing.bucketStart(from: iso))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try XCTUnwrap(formatter.date(from: iso))
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let expected = Date(timeIntervalSince1970: Double((seconds / 1800) * 1800))
        XCTAssertEqual(start, expected)
        XCTAssertEqual(Int(start.timeIntervalSince1970) % 1800, 0)
    }

    func test_bucketStart_invalidOrMissingTimestampReturnsNil() {
        XCTAssertNil(PiUsageProcessing.bucketStart(from: nil))
        XCTAssertNil(PiUsageProcessing.bucketStart(from: "  "))
        XCTAssertNil(PiUsageProcessing.bucketStart(from: "not-a-date"))
        XCTAssertNil(PiUsageProcessing.bucketStart(from: "2026-13-45T99:00:00Z"))
    }

    // MARK: - 路径会话 id

    func test_derivedSessionID_topLevelAndNestedSubagent() {
        let top = URL(fileURLWithPath: "/tmp/sessions/--Users-seam-proj--/2026-10-22T03-28-06-230Z_01a161a6-d655-7217-90e9-911de238f142.jsonl")
        XCTAssertEqual(PiUsageProcessing.derivedSessionID(from: top), "01a161a6-d655-7217-90e9-911de238f142")

        let nested = URL(fileURLWithPath: "/tmp/sessions/--Users-seam-proj--/2026-07-10T06-01-45-585Z_019f4a9e-2371-7000-ad7d-d32c511b23b3/CodeReviewer.jsonl")
        XCTAssertEqual(
            PiUsageProcessing.derivedSessionID(from: nested),
            "019f4a9e-2371-7000-ad7d-d32c511b23b3-CodeReviewer",
            "OMP 子代理用父会话目录 + Agent 文件名"
        )
    }

    func test_derivedSessionID_ignoresUnderscoreInEncodedCwdAndFallsBackToStem() {
        let underscored = URL(fileURLWithPath: "/tmp/sessions/--Users-seam-my_proj--/2026-10-22T03-28-06-230Z_abc123.jsonl")
        XCTAssertEqual(PiUsageProcessing.derivedSessionID(from: underscored), "abc123")

        let plain = URL(fileURLWithPath: "/tmp/sessions/--Users-seam-proj--/notes.jsonl")
        XCTAssertEqual(PiUsageProcessing.derivedSessionID(from: plain), "notes")
    }

    func test_normalized_trimsAndDropsBlank() {
        XCTAssertEqual(PiUsageProcessing.normalized("  x  "), "x")
        XCTAssertNil(PiUsageProcessing.normalized("   "))
        XCTAssertNil(PiUsageProcessing.normalized(nil))
    }
}
