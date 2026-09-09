import XCTest
@testable import OmniForge

/// OpenAI 兼容客户端：endpoint 规范化、请求形状、错误映射、响应解析。
final class PromptOptimizerServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeService(
        baseURL: String = "https://api.deepseek.com/v1",
        model: String = "deepseek-chat",
        apiKey: String = "sk-test"
    ) -> PromptOptimizerService {
        PromptOptimizerService(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            session: URLProtocolStub.makeSession()
        )
    }

    private func successBody(content: String) -> Data {
        let object: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - endpoint 规范化

    func test_endpointURL_appendsChatCompletionsPath() {
        XCTAssertEqual(
            PromptOptimizerService.endpointURL(forBaseURL: "https://api.deepseek.com/v1")?.absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
    }

    func test_endpointURL_trimsTrailingSlashes() {
        XCTAssertEqual(
            PromptOptimizerService.endpointURL(forBaseURL: "https://api.deepseek.com/v1//")?.absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
    }

    func test_endpointURL_keepsCompletePathVerbatim() {
        XCTAssertEqual(
            PromptOptimizerService.endpointURL(forBaseURL: "https://example.com/chat/completions")?.absoluteString,
            "https://example.com/chat/completions"
        )
    }

    func test_endpointURL_emptyBaseReturnsNil() {
        XCTAssertNil(PromptOptimizerService.endpointURL(forBaseURL: "  "))
        XCTAssertNil(PromptOptimizerService.endpointURL(forBaseURL: ""))
    }

    // MARK: - 请求形状

    func test_optimize_sendsTwoPartMessagesWithBearerAuth() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: successBody(content: "优化后的提示词"))

        _ = try await makeService().optimize(selectedText: "原始提示词")

        let request = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")

        let body = try XCTUnwrap(URLProtocolStub.recordedBodies.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-chat")
        XCTAssertEqual(object["stream"] as? Bool, false)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        let userContent = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(userContent.contains("原始提示词"), "选中文本进入 user 消息")
    }

    // MARK: - 成功与解析

    func test_optimize_returnsFirstChoiceContent() async throws {
        URLProtocolStub.stub = .init(statusCode: 200, data: successBody(content: "优化结果"))

        let result = try await makeService().optimize(selectedText: "输入")

        XCTAssertEqual(result, "优化结果")
    }

    func test_optimize_malformedResponseThrowsGeneric() async {
        URLProtocolStub.stub = .init(statusCode: 200, data: Data("{\"choices\": []}".utf8))

        await assertThrowsKind(.generic) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    func test_optimize_emptyContentThrowsGeneric() async {
        URLProtocolStub.stub = .init(statusCode: 200, data: successBody(content: "  "))

        await assertThrowsKind(.generic) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    // MARK: - 错误映射

    func test_optimize_401MapsToUnauthorized() async {
        URLProtocolStub.stub = .init(statusCode: 401)
        await assertThrowsKind(.unauthorized) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    func test_optimize_403MapsToUnauthorized() async {
        URLProtocolStub.stub = .init(statusCode: 403)
        await assertThrowsKind(.unauthorized) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    func test_optimize_500MapsToGeneric() async {
        URLProtocolStub.stub = .init(statusCode: 500)
        await assertThrowsKind(.generic) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    func test_optimize_timedOutURLErrorMapsToTimeout() async {
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.timedOut))
        await assertThrowsKind(.timeout) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    func test_optimize_connectionErrorMapsToNetwork() async {
        URLProtocolStub.stub = .init(statusCode: 0, error: URLError(.cannotConnectToHost))
        await assertThrowsKind(.network) {
            try await self.makeService().optimize(selectedText: "输入")
        }
    }

    func test_optimize_invalidBaseURLThrowsGeneric() async {
        await assertThrowsKind(.generic) {
            try await self.makeService(baseURL: "  ").optimize(selectedText: "输入")
        }
    }

    // MARK: - 工具

    private func assertThrowsKind(
        _ expected: PromptOptimizerErrorKind,
        _ expression: () async throws -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("期望抛出 \(expected)", file: file, line: line)
        } catch let error as PromptOptimizerErrorKind {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("期望 PromptOptimizerErrorKind，实际 \(error)", file: file, line: line)
        }
    }
}
