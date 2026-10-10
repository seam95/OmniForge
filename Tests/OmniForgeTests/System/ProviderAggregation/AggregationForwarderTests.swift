import XCTest
@testable import OmniForge
import Network

/// 上游转发：流式逐块（不等整 Body）、base/凭证重写、响应头剔 content-encoding/length、
/// 非 2xx 原样透传、上游不可达报错。
final class AggregationForwarderTests: XCTestCase {
    private var forwarder: AggregationURLSessionForwarder!

    override func setUp() {
        forwarder = AggregationURLSessionForwarder()
    }

    // MARK: - fixtures

    private func makeRequest(method: String, path: String, body: String, headers: [String: String]) -> AggregationHTTPRequest {
        AggregationHTTPRequest(
            head: AggregationRequestHead(
                method: method,
                path: path,
                query: "",
                headers: headers,
                contentLength: Data(body.utf8).count
            ),
            body: Data(body.utf8)
        )
    }

    private var messagesRequest: AggregationHTTPRequest {
        makeRequest(
            method: "POST",
            path: "/v1/messages",
            body: #"{"model":"k3"}"#,
            headers: ["content-type": "application/json", "x-api-key": "PROXY_MANAGED",
                      "anthropic-version": "2023-06-01", "accept-encoding": "gzip, br"]
        )
    }

    private var responsesRequest: AggregationHTTPRequest {
        makeRequest(
            method: "POST",
            path: "/v1/responses",
            body: #"{"model":"x"}"#,
            headers: ["content-type": "application/json", "authorization": "Bearer PROXY_MANAGED",
                      "accept-encoding": "gzip, br"]
        )
    }

    private func awaitForward(
        request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol
    ) throws -> AggregationHTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<AggregationHTTPResponse, Error>?
        forwarder.forward(request, to: target, protocol: `protocol`) { result in
            outcome = result
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success, "forward 未在超时内回调")
        return try XCTUnwrap(outcome).get()
    }

    // MARK: - tests

    func test_stream_relaysChunksIncrementallyRatherThanBuffering() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
            chunks: ["data: one\n\n", "data: two\n\n"],
            delayBeforeSecondChunk: 0.4
        )
        defer { stub.stop() }
        let target = AggregationProxyTarget(
            key: "kimi", profileID: "kimi",
            baseURL: "http://127.0.0.1:\(stub.port)", token: "sk-kimi"
        )

        let expectation = expectation(description: "stream completes")
        var firstChunkTime = Date.distantPast
        var completionTime = Date.distantPast

        forwarder.stream(request: messagesRequest, to: target, protocol: .anthropicMessages,
                         onChunk: { _ in if firstChunkTime == .distantPast { firstChunkTime = Date() } },
                         onComplete: { _ in completionTime = Date(); expectation.fulfill() })

        wait(for: [expectation], timeout: 5)
        // 第二块延迟 0.4s 后才发：首块到达必须显著早于完成时刻，否则说明被缓冲了
        XCTAssertGreaterThan(completionTime.timeIntervalSince(firstChunkTime), 0.3)
    }

    func test_forward_rewritesBaseURLAndCredential() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n",
            chunks: ["{}"],
            delayBeforeSecondChunk: 0
        )
        defer { stub.stop() }
        let glmTarget = AggregationProxyTarget(
            key: "glm", profileID: "glm",
            baseURL: "http://127.0.0.1:\(stub.port)/v1", token: "sk-glm"
        )
        _ = try awaitForward(request: responsesRequest, to: glmTarget, protocol: .openAIResponses)
        XCTAssertEqual(stub.lastRequestPath, "/v1/responses")
        XCTAssertEqual(stub.lastAuthorizationHeader, "Bearer sk-glm")
        // 客户端的 accept-encoding 不透传（编码交 URLSession 自管——它会补自己的值）。
        XCTAssertNotEqual(stub.lastAcceptEncodingHeader, "gzip, br")
    }

    func test_forward_dropsUpstreamContentEncodingAndContentLength() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n",
            chunks: ["{}"],
            delayBeforeSecondChunk: 0
        )
        defer { stub.stop() }
        let target = AggregationProxyTarget(
            key: "kimi", profileID: "kimi",
            baseURL: "http://127.0.0.1:\(stub.port)", token: "sk-kimi"
        )
        let response = try awaitForward(request: messagesRequest, to: target, protocol: .anthropicMessages)
        XCTAssertNil(response.headers["content-encoding"])
        XCTAssertNil(response.headers["content-length"])
    }

    func test_forward_passesThroughNon2xxStatusAndBody() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 5\r\n\r\n",
            chunks: ["sorry"],
            delayBeforeSecondChunk: 0
        )
        defer { stub.stop() }
        let target = AggregationProxyTarget(
            key: "kimi", profileID: "kimi",
            baseURL: "http://127.0.0.1:\(stub.port)", token: "sk-kimi"
        )
        let response = try awaitForward(request: messagesRequest, to: target, protocol: .anthropicMessages)
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.body, Data("sorry".utf8))
    }

    func test_forward_reportsErrorWhenUpstreamUnreachable() throws {
        let dead = AggregationProxyTarget(key: "k", profileID: "k", baseURL: "http://127.0.0.1:1", token: "sk")
        XCTAssertThrowsError(try awaitForward(request: messagesRequest, to: dead, protocol: .anthropicMessages))
    }
}

// MARK: - Stub 上游服务

/// 一次性 stub 上游：记录最近请求的方法行目标与授权头，按给定响应头 + 分块体应答
/// （第二块起可带延迟，用于验证逐块转发）。
private final class StubUpstreamServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "StubUpstreamServer")
    private let responseHead: String
    private let chunks: [String]
    private let delayBeforeSecondChunk: TimeInterval
    private var hasStopped = false

    private(set) var lastRequestPath: String?
    private(set) var lastAuthorizationHeader: String?
    private(set) var lastAcceptEncodingHeader: String?

    init(responseHead: String, chunks: [String], delayBeforeSecondChunk: TimeInterval) throws {
        self.responseHead = responseHead
        self.chunks = chunks
        self.delayBeforeSecondChunk = delayBeforeSecondChunk
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(domain: "StubUpstreamServer", code: 1, userInfo: nil)
        }
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                if let data { buffer.append(data) }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || data == nil || isComplete {
                    self.record(buffer)
                    self.respond(on: connection)
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    private func record(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        if let requestLine = lines.first {
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2 { lastRequestPath = String(parts[1]) }
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "authorization": lastAuthorizationHeader = value
            case "accept-encoding": lastAcceptEncodingHeader = value
            default: break
            }
        }
    }

    private func respond(on connection: NWConnection) {
        var payload = Data(responseHead.utf8)
        if let first = chunks.first {
            payload.append(Data(first.utf8))
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.sendRemainingChunks(on: connection, from: 1)
        })
    }

    private func sendRemainingChunks(on connection: NWConnection, from index: Int) {
        guard index < chunks.count else {
            connection.cancel()
            return
        }
        if delayBeforeSecondChunk > 0 {
            Thread.sleep(forTimeInterval: delayBeforeSecondChunk)
        }
        connection.send(content: Data(chunks[index].utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendRemainingChunks(on: connection, from: index + 1)
        })
    }
}
