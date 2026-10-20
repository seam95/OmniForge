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

}

// MARK: - Stub 上游服务

/// 一次性 stub 上游：记录最近请求的方法行目标与授权头，按给定响应头 + 分块体应答。
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

// MARK: - Stub 模型列表

private final class StubModelLister: AggregationProxyModelListing {
    func publishedModels(tool: ProviderTool) -> [AggregationPublishedModel] { [] }
}
