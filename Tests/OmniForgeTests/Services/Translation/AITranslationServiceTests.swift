import Foundation
import ObjectiveC
import XCTest
@testable import OmniForge

// MARK: - 每测试隔离的 URLProtocol 桩

/// 为每个测试生成独立 URLProtocol 子类与会话状态的测试桩。
///
/// URLSession 会按类自行构造 URLProtocol 实例，无法直接注入实例状态。
/// 这里用 Objective-C 运行时生成「每个测试专属子类」，把响应配置与请求记录
/// 关联到该子类的类对象上；因此不同测试、不同会话之间不共享任何可变全局状态。
/// 注意：Swift 的 `type(of:)` 对动态 Objective-C 子类返回基类元数据，必须用 `object_getClass`。
final class TranslationStubURLProtocol: URLProtocol {
    /// 一次请求的预置结果。
    enum Outcome {
        case response(statusCode: Int, data: Data)
        case failure(Error)
        /// 不回调，模拟仍在进行中的请求（取消测试用）。
        case pending
    }

    /// 单个测试专属的响应配置与请求记录；内部加锁，可从任意线程访问。
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomeHandler: (URLRequest) -> Outcome
        private var requests: [URLRequest] = []
        private var bodies: [Data] = []
        private var stopLoadingCount = 0

        init(handler: @escaping (URLRequest) -> Outcome) {
            self.outcomeHandler = handler
        }

        func record(_ request: URLRequest) -> Outcome {
            let body = Self.requestBody(request)
            lock.lock()
            requests.append(request)
            bodies.append(body)
            let handler = outcomeHandler
            lock.unlock()
            return handler(request)
        }

        var recordedRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var recordedBodies: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodies
        }

        var recordedStopLoadingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return stopLoadingCount
        }

        func recordStopLoading() {
            lock.lock()
            stopLoadingCount += 1
            lock.unlock()
        }

        /// 读取请求体：可能位于 `httpBody`，也可能位于尚未消费的 `httpBodyStream`。
        private static func requestBody(_ request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private static let stateAssociation = UnsafeRawPointer(UnsafeMutablePointer<UInt8>.allocate(capacity: 1))

    /// 生成独立会话与该会话专属状态。
    static func makeSession(handler: @escaping (URLRequest) -> Outcome) -> (session: URLSession, state: State) {
        let state = State(handler: handler)
        let className = "TranslationStubURLProtocol_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        guard let stubClass = objc_allocateClassPair(TranslationStubURLProtocol.self, className, 0) else {
            fatalError("无法创建测试用 URLProtocol 子类")
        }
        objc_registerClassPair(stubClass)
        objc_setAssociatedObject(stubClass, stateAssociation, state, .OBJC_ASSOCIATION_RETAIN)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stubClass]
        return (URLSession(configuration: configuration), state)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch state.record(request) {
        case .response(let statusCode, let data):
            let url = request.url ?? URL(string: "https://stub.local")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .pending:
            // 保持请求挂起，等待测试取消。
            break
        }
    }

    override func stopLoading() {
        state?.recordStopLoading()
    }

    private var state: State? {
        guard let dynamicClass = object_getClass(self) else { return nil }
        return objc_getAssociatedObject(dynamicClass, Self.stateAssociation) as? State
    }
}

// MARK: - AITranslationService 测试

/// AI 翻译引擎：端点规范化、请求形状、鉴权头、错误映射与取消语义。
///
/// 所有网络用例都注入独立的 URLProtocol 桩会话，不请求真实服务。
@MainActor
final class AITranslationServiceTests: XCTestCase {
    private static let request = TranslationRequest(
        text: "Hello\n\nWorld",
        sourceLanguage: "en",
        targetLanguage: "zh-Hans"
    )

    // MARK: - 构造工具

    private func makeService(
        baseURL: String = "https://api.example.com/v1",
        model: String = "test-model",
        apiKey: String? = "test-key",
        timeout: TimeInterval = 30,
        session: URLSession
    ) -> AITranslationService {
        AITranslationService(
            configuration: AITranslationConfiguration(baseURL: baseURL, model: model, apiKey: apiKey),
            session: session,
            timeout: timeout
        )
    }

    private func successBody(_ content: String) -> Data {
        let object: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": content]]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func stubSession(
        statusCode: Int = 200,
        data: Data = Data()
    ) -> (session: URLSession, state: TranslationStubURLProtocol.State) {
        TranslationStubURLProtocol.makeSession { _ in
            .response(statusCode: statusCode, data: data)
        }
    }

    private func assertEndpointRejected(
        _ baseURL: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AITranslationService.endpointURL(forBaseURL: baseURL),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? TranslationError, .configurationIncomplete, file: file, line: line)
        }
    }

    private func assertThrowsTranslationError<Value>(
        _ expected: TranslationError,
        _ expression: () async throws -> Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("期望抛出 \(expected)", file: file, line: line)
        } catch let error as TranslationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("期望 TranslationError，实际 \(error)", file: file, line: line)
        }
    }

    /// 带超时的任务结果等待：取消语义失效时让测试失败而不是挂起。
    private func awaitOutcome(
        of task: Task<TranslationResult, Error>,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Result<TranslationResult, Error>? {
        let finished = expectation(description: "翻译任务在 \(timeout) 秒内结束")
        var outcome: Result<TranslationResult, Error>?
        Task {
            do {
                outcome = .success(try await task.value)
            } catch {
                outcome = .failure(error)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: timeout)
        return outcome
    }

    /// 轮询等待异步副作用落地（例如取消后 URLProtocol.stopLoading 回调）。
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - 端点规范化

    func test_endpointNormalization_preservesPrefixAndAvoidsDuplicateSuffix() throws {
        // 含 /v1 前缀的 Base URL：保留前缀并追加一次 /chat/completions。
        XCTAssertEqual(
            try AITranslationService.endpointURL(forBaseURL: "https://api.example.com/v1").absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        // 已含完整端点：不重复追加；尾斜杠与首尾空白被清理。
        XCTAssertEqual(
            try AITranslationService.endpointURL(
                forBaseURL: "  https://api.example.com/v1/chat/completions/  "
            ).absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        // 无 /v1 的自定义前缀同样只拼接一次。
        XCTAssertEqual(
            try AITranslationService.endpointURL(forBaseURL: "https://api.example.com/openai").absoluteString,
            "https://api.example.com/openai/chat/completions"
        )
    }

    func test_endpointRejectsRemoteHTTPAndEmbeddedCredentials() throws {
        // 远程明文 HTTP 与危险/不完整地址一律拒绝。
        assertEndpointRejected("http://api.example.com/v1")
        assertEndpointRejected("")
        assertEndpointRejected("   ")
        assertEndpointRejected("ftp://api.example.com/v1")
        assertEndpointRejected("https:///v1")
        assertEndpointRejected("https://user:pass@api.example.com/v1")
        assertEndpointRejected("https://api.example.com/v1?key=1")
        assertEndpointRejected("https://api.example.com/v1#section")

        // 本机回环地址允许 HTTP，便于无鉴权本地服务。
        let loopbackBaseURLs = [
            "http://localhost:8080/v1",
            "http://127.0.0.1:11434/v1",
            "http://[::1]:8080/v1",
        ]
        for baseURL in loopbackBaseURLs {
            XCTAssertEqual(
                try AITranslationService.endpointURL(forBaseURL: baseURL).absoluteString,
                baseURL + "/chat/completions"
            )
        }
        // 远程 HTTPS 正常。
        XCTAssertNoThrow(try AITranslationService.endpointURL(forBaseURL: "https://api.example.com/v1"))
    }

    // MARK: - 请求形状与鉴权

    func test_blankKeyOmitsAuthorization() async throws {
        let keys: [String?] = [nil, "", "   "]
        for apiKey in keys {
            let stub = stubSession(data: successBody("译文"))
            let service = makeService(apiKey: apiKey, session: stub.session)

            _ = try await service.translate(Self.request)

            let recorded = try XCTUnwrap(stub.state.recordedRequests.last)
            XCTAssertNil(recorded.value(forHTTPHeaderField: "Authorization"), "Key 为空时不应发送鉴权头")
        }
    }

    func test_keySetsBearerAuthorization() async throws {
        let stub = stubSession(data: successBody("译文"))
        let service = makeService(apiKey: "test-key", session: stub.session)

        _ = try await service.translate(Self.request)

        let recorded = try XCTUnwrap(stub.state.recordedRequests.last)
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func test_translateSendsOpenAIChatCompletionsRequest() async throws {
        let stub = stubSession(data: successBody("你好，世界"))
        let service = makeService(session: stub.session)

        _ = try await service.translate(Self.request)

        let recorded = try XCTUnwrap(stub.state.recordedRequests.last)
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(recorded.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(recorded.timeoutInterval, 30)

        let body = try XCTUnwrap(stub.state.recordedBodies.last)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertEqual(object["stream"] as? Bool, false)

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        // 指令写在 system 消息，要求只返回译文、保留段落，并包含目标语言。
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        let systemContent = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(systemContent.contains("zh-Hans"), "system 消息应包含目标语言")
        XCTAssertTrue(systemContent.contains("only the translated text"), "system 消息应约束只返回译文")
        XCTAssertTrue(systemContent.contains("paragraph"), "system 消息应要求保留段落")
        // 原文只作为 user 消息的待翻译数据，不被改写。
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, Self.request.text)
    }

    func test_translateReturnsAIResultWithModel() async throws {
        let stub = stubSession(data: successBody("你好，世界"))
        let service = makeService(session: stub.session)

        let result = try await service.translate(Self.request)

        XCTAssertEqual(result.text, "你好，世界")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertEqual(result.targetLanguage, "zh-Hans")
        XCTAssertEqual(result.engine, .ai)
        XCTAssertEqual(result.model, "test-model")
    }

    func test_connectionProbeUsesFixedText() async throws {
        let stub = stubSession(data: successBody("Hi there"))
        let service = makeService(session: stub.session)

        let probeResult = try await service.testConnection()

        XCTAssertEqual(probeResult, "Hi there")
        let recorded = try XCTUnwrap(stub.state.recordedRequests.last)
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.example.com/v1/chat/completions")

        let body = try XCTUnwrap(stub.state.recordedBodies.last)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["stream"] as? Bool, false)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        // 连接测试只发送一条固定短文本，不发送当前会话原文。
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, AITranslationService.connectionProbeText)
        XCTAssertFalse(
            (messages[0]["content"] as? String ?? "").contains(Self.request.text),
            "连接测试不得包含会话原文"
        )
    }

    // MARK: - 错误映射

    func test_errorMapping_unauthorized() async {
        for statusCode in [401, 403] {
            let stub = stubSession(statusCode: statusCode)
            let service = makeService(session: stub.session)
            await assertThrowsTranslationError(.unauthorized) {
                try await service.translate(Self.request)
            }
        }
    }

    func test_errorMapping_rateLimited() async {
        let stub = stubSession(statusCode: 429)
        let service = makeService(session: stub.session)
        await assertThrowsTranslationError(.rateLimited) {
            try await service.translate(Self.request)
        }
    }

    func test_errorMapping_serverFailure() async {
        for statusCode in [400, 500, 503] {
            let stub = stubSession(statusCode: statusCode)
            let service = makeService(session: stub.session)
            await assertThrowsTranslationError(.serverError(statusCode: statusCode)) {
                try await service.translate(Self.request)
            }
        }
    }

    func test_errorMapping_networkFailure() async {
        let stub = TranslationStubURLProtocol.makeSession { _ in
            .failure(URLError(.cannotConnectToHost))
        }
        let service = makeService(session: stub.session)
        await assertThrowsTranslationError(.network) {
            try await service.translate(Self.request)
        }
    }

    func test_errorMapping_timeout() async {
        let stub = TranslationStubURLProtocol.makeSession { _ in
            .failure(URLError(.timedOut))
        }
        let service = makeService(session: stub.session)
        await assertThrowsTranslationError(.timedOut) {
            try await service.translate(Self.request)
        }
    }

    func test_invalidResponseForEmptyChoices() async {
        let stub = stubSession(data: Data("{\"choices\":[]}".utf8))
        let service = makeService(session: stub.session)
        await assertThrowsTranslationError(.invalidResponse) {
            try await service.translate(Self.request)
        }
    }

    func test_invalidResponseForEmptyContent() async {
        let stub = stubSession(data: successBody("   \n  "))
        let service = makeService(session: stub.session)
        await assertThrowsTranslationError(.invalidResponse) {
            try await service.translate(Self.request)
        }
    }

    func test_invalidResponseForNonJSONBody() async {
        let stub = stubSession(data: Data("not-json".utf8))
        let service = makeService(session: stub.session)
        await assertThrowsTranslationError(.invalidResponse) {
            try await service.translate(Self.request)
        }
    }

    func test_invalidEndpointThrowsConfigurationIncomplete() async {
        let stub = stubSession(data: successBody("译文"))
        let service = makeService(baseURL: "http://api.example.com/v1", session: stub.session)
        await assertThrowsTranslationError(.configurationIncomplete) {
            try await service.translate(Self.request)
        }
    }

    func test_emptyModelThrowsConfigurationIncomplete() async {
        let stub = stubSession(data: successBody("译文"))
        let service = makeService(model: "   ", session: stub.session)
        await assertThrowsTranslationError(.configurationIncomplete) {
            try await service.translate(Self.request)
        }
    }

    // MARK: - 取消

    func test_cancelledRequestRemainsCancellation() async throws {
        let requestStarted = expectation(description: "请求已到达 URLProtocol")
        let stub = TranslationStubURLProtocol.makeSession { _ in
            requestStarted.fulfill()
            return .pending
        }
        let service = makeService(session: stub.session)

        let task = Task { try await service.translate(Self.request) }
        await fulfillment(of: [requestStarted], timeout: 5)
        task.cancel()

        let outcome = await awaitOutcome(of: task)
        guard let outcome else {
            XCTFail("父任务取消后请求未结束")
            return
        }
        switch outcome {
        case .success:
            XCTFail("取消的请求不应成功返回")
        case .failure(let error):
            // 取消保持 CancellationError 语义，不显示成网络错误。
            XCTAssertTrue(error is CancellationError, "取消应抛 CancellationError，实际 \(error)")
        }
    }

    func test_cancelStopsOutstandingRequest() async throws {
        let requestStarted = expectation(description: "请求已到达 URLProtocol")
        let stub = TranslationStubURLProtocol.makeSession { _ in
            requestStarted.fulfill()
            return .pending
        }
        let service = makeService(session: stub.session)

        let task = Task { try await service.translate(Self.request) }
        await fulfillment(of: [requestStarted], timeout: 5)
        service.cancel()

        let outcome = await awaitOutcome(of: task)
        guard let outcome else {
            XCTFail("service.cancel() 后请求未结束")
            return
        }
        switch outcome {
        case .success:
            XCTFail("取消的请求不应成功返回")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "取消应抛 CancellationError，实际 \(error)")
        }
        // 底层 URLSession 任务被终止：URLProtocol 收到 stopLoading 回调。
        let stopped = await waitUntil { stub.state.recordedStopLoadingCount >= 1 }
        XCTAssertTrue(stopped, "取消应终止底层 URLSession 任务")
    }

    func test_cancelWithoutOutstandingRequestIsNoOp() {
        let stub = stubSession()
        let service = makeService(session: stub.session)

        // 幂等空操作：不崩溃、不发请求。
        service.cancel()
        service.cancel()

        XCTAssertTrue(stub.state.recordedRequests.isEmpty)
    }
}
