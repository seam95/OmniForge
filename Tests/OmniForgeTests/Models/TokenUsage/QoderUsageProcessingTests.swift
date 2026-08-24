import XCTest
@testable import OmniForge

/// qoder token_info / 模型链 / 消息 key 解析。
final class QoderUsageProcessingTests: XCTestCase {

    // MARK: - token_info

    func test_normalizedTotals_splitsCachedFromPrompt() {
        let totals = QoderUsageProcessing.normalizedTotals(from: #"{"prompt_tokens":1000,"cached_tokens":200,"completion_tokens":300}"#)
        XCTAssertNotNil(totals)
        XCTAssertEqual(totals?.inputTokens, 800, "prompt 含 cached → 拆分")
        XCTAssertEqual(totals?.cachedInputTokens, 200)
        XCTAssertEqual(totals?.outputTokens, 300)
        XCTAssertEqual(totals?.totalTokens, 1300, "total = prompt + completion")
    }

    func test_normalizedTotals_nilForInvalid() {
        XCTAssertNil(QoderUsageProcessing.normalizedTotals(from: nil))
        XCTAssertNil(QoderUsageProcessing.normalizedTotals(from: ""))
        XCTAssertNil(QoderUsageProcessing.normalizedTotals(from: "{}"))
        XCTAssertNil(QoderUsageProcessing.normalizedTotals(from: #"{"prompt_tokens":-5,"completion_tokens":1}"#))
        XCTAssertNil(QoderUsageProcessing.normalizedTotals(from: "not json"))
    }

    // MARK: - 模型链

    func test_modelName_chain() {
        XCTAssertEqual(
            QoderUsageProcessing.modelName(
                modelInfo: #"{"model_key":"deepseek-v4"}"#,
                recordExtra: nil,
                preferredModelInfo: nil
            ),
            "deepseek-v4"
        )
        XCTAssertEqual(
            QoderUsageProcessing.modelName(
                modelInfo: nil,
                recordExtra: #"{"modelConfig":{"key":"glm-4.6"}}"#,
                preferredModelInfo: nil
            ),
            "glm-4.6"
        )
        XCTAssertEqual(
            QoderUsageProcessing.modelName(
                modelInfo: nil,
                recordExtra: nil,
                preferredModelInfo: #"{"preferred_model":"qoder-flash"}"#
            ),
            "qoder-flash"
        )
        XCTAssertEqual(
            QoderUsageProcessing.modelName(modelInfo: nil, recordExtra: nil, preferredModelInfo: nil),
            "qoder-agent"
        )
    }

    // MARK: - key

    func test_messageKey_chain() {
        XCTAssertEqual(QoderUsageProcessing.messageKey(id: "m1", sessionID: "s1", rowID: 3), "s1|m1")
        XCTAssertEqual(QoderUsageProcessing.messageKey(id: "m1", sessionID: nil, rowID: 3), "m1")
        XCTAssertEqual(QoderUsageProcessing.messageKey(id: nil, sessionID: nil, rowID: 7), "row:7")
        XCTAssertNil(QoderUsageProcessing.messageKey(id: nil, sessionID: nil, rowID: nil))
    }

    func test_requestKey_prefersRequestID() {
        XCTAssertEqual(QoderUsageProcessing.requestKey(requestID: "r1", sessionID: "s1", messageKey: "k"), "r1")
        XCTAssertEqual(QoderUsageProcessing.requestKey(requestID: nil, sessionID: "s1", messageKey: "k"), "s1")
        XCTAssertEqual(QoderUsageProcessing.requestKey(requestID: nil, sessionID: nil, messageKey: "k"), "k")
    }
}