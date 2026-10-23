import XCTest
@testable import OmniForge
import Network

/// 端到端（真 socket）：普通请求经真 listener 转发到 stub 上游、miss 经真 listener 返 400、
/// SSE 分块响应经流式转发不截断。
final class AggregationProxyEndToEndTests: XCTestCase {
    private var forwarder: AggregationURLSessionForwarder!
    private var defaults: UserDefaults!

    override func setUp() {
        forwarder = AggregationURLSessionForwarder()
        // 隔离的 defaults 域：不碰标准域（真实 App 的端口持久化键）。
        let suiteName = "AggregationProxyE2E_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeProxy(defaultTarget: AggregationProxyTarget?) -> AggregationProxy {
        AggregationProxy(
            resolver: AggregationTargetResolver(
                stack: .init(enabled: true, members: [], keys: [:]),
                registry: AggregationKeyRegistry(),
                profiles: [],
                defaultTarget: defaultTarget
            ),
            modelLister: StubModelLister(),
            forwarder: forwarder,
            sealStore: AggregationRefusedSealStore(),
            defaults: defaults
        )
    }

    private func stubTarget(_ stub: StubUpstreamServer) -> AggregationProxyTarget {
        AggregationProxyTarget(
            key: "deepseek", profileID: "deepseek",
            baseURL: "http://127.0.0.1:\(stub.port)", token: "sk-ds"
        )
    }

    /// 经代理发一次 POST，同步拿回状态码与体。
    ///
    /// 每个请求用独立 ephemeral session：代理按设计一连接一请求，
    /// 共享 session 的 keep-alive 复用会撞上已关闭的连接。
    private func postThroughProxy(port: UInt16, path: String, body: String) throws -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var received: (Int, Data)?
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        session.dataTask(with: request) { data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            received = (statusCode, data ?? Data())
            semaphore.signal()
        }.resume()
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success, "代理未在超时内应答")
        session.invalidateAndCancel()
        return try XCTUnwrap(received)
    }

    func test_endToEnd_plainRequestForwardsThroughRealListener() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n",
            chunks: ["{}"],
            delayBeforeSecondChunk: 0
        )
        defer { stub.stop() }
        let proxy = makeProxy(defaultTarget: stubTarget(stub))
        try proxy.start()
        defer { proxy.stop() }
        let port = try XCTUnwrap(proxy.resolvedPort)

        let (statusCode, body) = try postThroughProxy(port: port, path: "/v1/messages", body: #"{"model":"claude-sonnet-4-6"}"#)
        XCTAssertEqual(statusCode, 200)
        XCTAssertEqual(body, Data("{}".utf8))
        XCTAssertEqual(stub.lastRequestPath, "/v1/messages")
    }

    func test_endToEnd_missReturns400ThroughRealListener() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n",
            chunks: ["{}"],
            delayBeforeSecondChunk: 0
        )
        defer { stub.stop() }
        let proxy = makeProxy(defaultTarget: stubTarget(stub))
        try proxy.start()
        defer { proxy.stop() }
        let port = try XCTUnwrap(proxy.resolvedPort)

        let (statusCode, body) = try postThroughProxy(port: port, path: "/v1/messages", body: #"{"model":"om-claude-nobody--x"}"#)
        XCTAssertEqual(statusCode, 400)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "error")
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertTrue((error["message"] as? String)?.contains("OmniForge") == true)
    }

    func test_endToEnd_sseBodyIsNotTruncated() throws {
        let stub = try StubUpstreamServer(
            responseHead: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n",
            chunks: ["data: one\n\n", "data: two\n\n"],
            delayBeforeSecondChunk: 0.1
        )
        defer { stub.stop() }
        let proxy = makeProxy(defaultTarget: stubTarget(stub))
        try proxy.start()
        defer { proxy.stop() }
        let port = try XCTUnwrap(proxy.resolvedPort)

        let (statusCode, body) = try postThroughProxy(port: port, path: "/v1/messages", body: #"{"model":"claude-sonnet-4-6"}"#)
        XCTAssertEqual(statusCode, 200)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("data: one"), "首块必须到达")
        XCTAssertTrue(text.contains("data: two"), "末块必须到达——close-delimited 不得截断")
    }

    /// 4xx 错误体超过缓冲上限时也要完整写回，不能因为提前清空 pendingBody 丢体。
    func test_endToEnd_large4xxBodyIsNotDropped() throws {
        let big = String(repeating: "x", count: 70 * 1024)
        let errorBody = #"{"error":{"message":"\#(big)"}}"#
        let head = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(errorBody.utf8.count)\r\n\r\n"
        let stub = try StubUpstreamServer(responseHead: head, chunks: [errorBody], delayBeforeSecondChunk: 0)
        defer { stub.stop() }
        let proxy = makeProxy(defaultTarget: stubTarget(stub))
        try proxy.start()
        defer { proxy.stop() }
        let port = try XCTUnwrap(proxy.resolvedPort)

        let (statusCode, data) = try postThroughProxy(
            port: port, path: "/v1/responses", body: #"{"model":"m","input":[]}"#
        )
        XCTAssertEqual(statusCode, 400)
        XCTAssertEqual(data.count, errorBody.utf8.count, "超限错误体必须完整转发")
    }

    /// 跨供应商 sealed reasoning：上游 400 报 `invalid_encrypted_content` 时，
    /// 代理去掉 reasoning 重试；客户端只看到最终 200，不看到第一次失败。
    func test_endToEnd_foreignSealRetriesWithoutReasoning() throws {
        let errorBody = #"{"error":{"message":"The encrypted content for item rs_1 could not be verified.","code":"invalid_encrypted_content"}}"#
        let errorHead = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(errorBody.utf8.count)\r\n\r\n"
        let stub = try StubUpstreamServer(responses: [
            (head: errorHead, chunks: [errorBody]),
            (head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n", chunks: ["{}"]),
        ])
        defer { stub.stop() }
        let proxy = makeProxy(defaultTarget: stubTarget(stub))
        try proxy.start()
        defer { proxy.stop() }
        let port = try XCTUnwrap(proxy.resolvedPort)

        let body = #"{"model":"deepseek-reasoner","input":[{"type":"reasoning","id":"rs_1","encrypted_content":"sealed-x"},{"type":"message","role":"user"}]}"#
        let (statusCode, data) = try postThroughProxy(port: port, path: "/v1/responses", body: body)

        XCTAssertEqual(statusCode, 200, "重试对客户端透明")
        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(stub.requestCount, 2, "第一次 400 后必须重试一次")
        if stub.requestBodies.count >= 2 {
            XCTAssertFalse(stub.requestBodies[1].contains("\"reasoning\""), "重试体不得再带 reasoning")
        }
    }
}

// MARK: - Stub 上游服务

/// 一次性 stub 上游：记录最近请求的方法行目标与授权头，按给定响应头 + 分块体应答。
private final class StubUpstreamServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "StubUpstreamServer")
    private let responseHead: String
    private let chunks: [String]
    private let sequence: [(head: String, chunks: [String])]?
    private var sequenceIndex = 0
    private let delayBeforeSecondChunk: TimeInterval
    private var hasStopped = false

    private(set) var lastRequestPath: String?
    private(set) var lastAuthorizationHeader: String?
    private(set) var lastAcceptEncodingHeader: String?
    private(set) var requestCount = 0
    private(set) var requestBodies: [String] = []

    init(responseHead: String, chunks: [String], delayBeforeSecondChunk: TimeInterval) throws {
        self.responseHead = responseHead
        self.chunks = chunks
        self.sequence = nil
        self.delayBeforeSecondChunk = delayBeforeSecondChunk
        listener = try NWListener(using: .tcp, on: .any)
        try startListener()
    }

    /// 按顺序为每个请求返回一份响应（用于验证代理的透明重试）。
    init(responses: [(head: String, chunks: [String])], delayBeforeSecondChunk: TimeInterval = 0) throws {
        self.responseHead = responses.first?.head ?? "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        self.chunks = responses.first?.chunks ?? []
        self.sequence = responses
        self.delayBeforeSecondChunk = delayBeforeSecondChunk
        listener = try NWListener(using: .tcp, on: .any)
        try startListener()
    }

    private func startListener() throws {
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
        requestCount += 1
        if let body = text.components(separatedBy: "\r\n\r\n").dropFirst().first {
            requestBodies.append(body)
        }
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
        let head: String
        let bodyChunks: [String]
        if let sequence, !sequence.isEmpty {
            let index = min(sequenceIndex, sequence.count - 1)
            sequenceIndex += 1
            head = sequence[index].head
            bodyChunks = sequence[index].chunks
        } else {
            head = responseHead
            bodyChunks = chunks
        }
        var payload = Data(head.utf8)
        if let first = bodyChunks.first {
            payload.append(Data(first.utf8))
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.sendRemainingChunks(on: connection, chunks: bodyChunks, from: 1)
        })
    }

    private func sendRemainingChunks(on connection: NWConnection, chunks: [String], from index: Int) {
        guard index < chunks.count else {
            connection.cancel()
            return
        }
        if delayBeforeSecondChunk > 0 {
            Thread.sleep(forTimeInterval: delayBeforeSecondChunk)
        }
        connection.send(content: Data(chunks[index].utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendRemainingChunks(on: connection, chunks: chunks, from: index + 1)
        })
    }
}

// MARK: - Stub 模型列表

private final class StubModelLister: AggregationProxyModelListing {
    func publishedModels(tool: ProviderTool) -> [AggregationPublishedModel] { [] }
}
