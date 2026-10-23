import XCTest
@testable import OmniForge

/// 跨供应商 sealed reasoning/compaction 的清洗与重试决策。
final class AggregationSealGuardTests: XCTestCase {
    private let body = Data(#"""
    {"model":"m","input":[
      {"type":"message","role":"user","content":[]},
      {"type":"reasoning","id":"rs_1","encrypted_content":"sealed-a"},
      {"type":"compaction","encrypted_content":"sealed-c"},
      {"type":"reasoning","id":"rs_2","encrypted_content":null},
      {"type":"function_call","call_id":"c1","name":"shell","arguments":"{}"}
    ]}
    """#.utf8)

    private func items(_ body: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["input"] as? [[String: Any]])
    }

    func test_removingReasoningKeepsOtherItems() throws {
        let out = try XCTUnwrap(AggregationSealSanitizer.removingReasoning(from: body))
        let kept = try items(out)
        XCTAssertEqual(kept.compactMap { $0["type"] as? String }, ["message", "compaction", "function_call"])
    }

    func test_removingCompactionKeepsOtherItems() throws {
        let out = try XCTUnwrap(AggregationSealSanitizer.removingCompaction(from: body))
        let kept = try items(out)
        XCTAssertEqual(kept.compactMap { $0["type"] as? String }, ["message", "reasoning", "reasoning", "function_call"])
    }

    func test_sealsHashesOnlyEncryptedItems() {
        let seals = AggregationSealSanitizer.seals(in: body)
        XCTAssertEqual(seals.count, 2, "reasoning 与 compaction 各一条；空 encrypted_content 不算")
        XCTAssertEqual(Set(seals).count, 2)
    }

    func test_foreignSealErrorRecognizesKnownMessages() {
        XCTAssertTrue(AggregationSealSanitizer.isForeignSealError(Data(
            #"{"error":{"message":"The encrypted content for item rs_1 could not be verified.","code":"invalid_encrypted_content"}}"#.utf8
        )))
        XCTAssertTrue(AggregationSealSanitizer.isForeignSealError(Data(
            #"{"error":{"message":"Could not decrypt the provided encrypted_content. Ensure the value is the unmodified encrypted_content from a previous response."}}"#.utf8
        )))
        XCTAssertFalse(AggregationSealSanitizer.isForeignSealError(Data(
            #"{"error":{"message":"rate limit exceeded"}}"#.utf8
        )))
    }

    func test_retryBodyRemovesReasoningFirstThenCompaction() throws {
        let error = Data(#"{"error":{"message":"invalid_encrypted_content"}}"#.utf8)

        let first = try XCTUnwrap(AggregationSealSanitizer.retryBody(
            after: body, errorBody: error, attempt: 0
        ))
        XCTAssertEqual(first.seals.count, 2)
        XCTAssertEqual(try items(first.body).compactMap { $0["type"] as? String },
                       ["message", "compaction", "function_call"])

        let second = try XCTUnwrap(AggregationSealSanitizer.retryBody(
            after: first.body, errorBody: error, attempt: 1
        ))
        XCTAssertEqual(try items(second.body).compactMap { $0["type"] as? String },
                       ["message", "function_call"])

        XCTAssertNil(AggregationSealSanitizer.retryBody(
            after: second.body, errorBody: error, attempt: 2
        ), "最多重试两次")
    }

    func test_retryBodyNilForUnrelatedError() {
        XCTAssertNil(AggregationSealSanitizer.retryBody(
            after: body, errorBody: Data(#"{"error":{"message":"bad request"}}"#.utf8), attempt: 0
        ))
    }

    func test_refusedStorePrecleansLaterRequests() throws {
        let store = AggregationRefusedSealStore()
        store.reset()
        store.record(targetKey: "kimi", seals: AggregationSealSanitizer.seals(in: body))

        let cleaned = try XCTUnwrap(store.removingRefused(from: body, targetKey: "kimi"))
        let kept = try items(cleaned)
        XCTAssertEqual(kept.count, 3, "两条 sealed item 被去掉，空 encrypted 的 reasoning 留给 bare 清洗")
        XCTAssertEqual(kept.compactMap { $0["id"] as? String }, ["rs_2"])

        XCTAssertNil(store.removingRefused(from: body, targetKey: "deepseek"),
                     "别的目标不受影响")
    }
}
