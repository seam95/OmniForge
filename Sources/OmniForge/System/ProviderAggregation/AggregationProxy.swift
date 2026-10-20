import Foundation
import Network

/// 上游转发边界。完成式 `forward` 供单测/冒烟聚合；生产数据面走流式 `stream`
/// （完成式会缓冲整个响应体，与 SSE 逐块转发冲突）。
protocol AggregationForwarding: AnyObject {
    func forward(
        _ request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol,
        completion: @escaping (Result<AggregationHTTPResponse, Error>) -> Void
    )
    /// 流式转发。`onHead` 在首块**之前**回调（连接层据此先写状态行与响应头）。
    func stream(
        request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol,
        onHead: @escaping (Int, [String: String]) -> Void,
        onChunk: @escaping (Data) -> Void,
        onComplete: @escaping (Error?) -> Void
    )
}

/// 已发布模型列表边界（发现端点用；按工具分别列——Anthropic 形状列 Claude 侧、
/// OpenAI 形状列 Codex 侧）。由编排层注入，Task 20 前用 stub。
protocol AggregationProxyModelListing: AnyObject {
    func publishedModels(tool: ProviderTool) -> [AggregationPublishedModel]
}

/// 分派判定结果：本地应答，或（可能已改写体的）转发。
enum AggregationDispatch: Equatable {
    case respond(AggregationHTTPResponse)
    case forward(request: AggregationHTTPRequest, target: AggregationProxyTarget, protocol: AggregationClientProtocol)
}

/// 代理启动失败。
enum AggregationProxyError: Error, Equatable {
    /// 端口探测全部被占（顺延 maxAttempts 次仍无可绑端口）——不写任何配置。
    case allPortsTaken
    /// 已在运行。
    case alreadyRunning
}

/// 代理服务边界（编排层持此协议；测试注入「必然启动失败」的 stub）。
protocol AggregationProxying: AnyObject {
    var isRunning: Bool { get }
    var resolvedPort: UInt16? { get }
    /// 代理异常退出（非主动 stop）时触发——编排层看门狗挂钩。
    var onUnexpectedStop: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// 聚合代理主体 — 判定与搬运分层：`dispatch` 是同步纯函数（路由表、miss 信封、
/// 模型名改写、发现端点在此完成判定，完全可测）；`handle` 把完成式 `forward`
/// 聚合起来，**仅供单测与 Task 20 以前的冒烟**——生产路径是本文件的 NWListener
/// 数据面：`dispatch` + Task 14 的 `stream` 流式转发（`handle` 会缓冲整个响应体，
/// 与 SSE 逐块转发的规格冲突）。
final class AggregationProxy: AggregationProxying {
    private let resolver: AggregationResolving
    private let modelLister: AggregationProxyModelListing
    private let forwarder: AggregationForwarding
    private let defaults: UserDefaults
    /// 连接数据面队列。每连接一个独立状态机，无共享可变状态。
    private let connectionQueue = DispatchQueue(label: "AggregationProxy.connections")

    /// 监听器。只在主线程访问（start/stop 与状态回调均收敛到主线程）。
    private var listener: NWListener?

    private(set) var resolvedPort: UInt16?
    var onUnexpectedStop: (() -> Void)?

    init(
        resolver: AggregationResolving,
        modelLister: AggregationProxyModelListing,
        forwarder: AggregationForwarding,
        defaults: UserDefaults = .standard
    ) {
        self.resolver = resolver
        self.modelLister = modelLister
        self.forwarder = forwarder
        self.defaults = defaults
    }

    // MARK: - 服务生命周期

    var isRunning: Bool { listener != nil }

    func start() throws {
        if isRunning { throw AggregationProxyError.alreadyRunning }
        // 编排层保证「先起代理、成功才写配置」；端口全占 → 抛错，调用方不写任何配置。
        guard let port = AggregationPortAllocator.resolvePersisted(defaults: defaults) else {
            throw AggregationProxyError.allPortsTaken
        }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            // 状态回调收敛到主线程：listener / resolvedPort 只在主线程访问。
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    // 非本实例主动 stop（self.listener 已换人/置空）才视为异常退出。
                    if self.listener === listener {
                        self.handleUnexpectedStop()
                    }
                default:
                    break
                }
            }
        }
        listener.start(queue: connectionQueue)
        self.listener = listener
        resolvedPort = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        resolvedPort = nil
    }

    private func handleUnexpectedStop() {
        listener = nil
        resolvedPort = nil
        onUnexpectedStop?()
    }

    // MARK: - 判定（同步纯函数）

    func dispatch(_ request: AggregationHTTPRequest) -> AggregationDispatch {
        let clientProtocol = AggregationRouteTable.protocolOf(
            method: request.head.method,
            path: request.head.path
        )
        switch clientProtocol {
        case .health:
            return .respond(Self.jsonResponse(statusCode: 200, body: ["status": "ok"]))
        // WebSocket 探测必须回 426：Codex 内置的 openai 默认先连 `/responses` 的 WebSocket，
        // 握手拿到 426 就在本会话内改走 HTTP；换成 404 或其他失败码会让 Codex 先把重试耗尽才回退
        // （cc-switch `handlers.rs:966-969` 的结论，响应形态见同文件 973-984）。
        case .websocketProbe:
            return .respond(Self.jsonResponse(
                statusCode: 426,
                body: ["error": ["type": "invalid_request_error",
                                 "code": "websocket_not_supported",
                                 "message": "OmniForge local routing does not support Responses over WebSocket; use HTTP"]]
            ))
        case .unsupported:
            return .respond(Self.jsonResponse(statusCode: 404, body: ["error": "not_found"]))
        case .modelDiscovery:
            if AggregationModelDiscovery.isModelDiscoveryRequest(
                method: request.head.method,
                path: request.head.path,
                headers: request.head.headers,
                query: request.head.query
            ) {
                // Anthropic 形状（Claude 的模型发现）。
                return .respond(Self.jsonDataResponse(
                    statusCode: 200,
                    body: AggregationModelDiscovery.responseBody(
                        published: modelLister.publishedModels(tool: .claudeCode)
                    )
                ))
            }
            // OpenAI 形状（Codex 可达性检查）。
            return .respond(Self.jsonDataResponse(
                statusCode: 200,
                body: Self.openAIModelListBody(published: modelLister.publishedModels(tool: .codex))
            ))
        // 透明端点（SPEC §9 / cc-switch `server.rs:299-425`）：alpha/images 体里没有聚合模型选择器，
        // 故**不做 Stack 解码**——请求体原样（连 `model` 字段也不看不改），只转发当前默认那家。
        // 拿默认目标用空模型名解析：`decode("")` 恒为 `.plain`，聚合 id 分支（`.hit`）不可达。
        // 没有默认目标时按 cc-switch 的 `NoProvidersConfigured` 回 **503**——不复用上面解码路径的 400
        // （那套信封语义是「模型选错了」，这里是「一家都没配」）。
        case .codexPassthrough:
            guard case .plain(let target) = resolver.resolve(tool: .codex, model: "") else {
                return .respond(Self.missResponse(
                    statusCode: 503,
                    message: "OmniForge has no default provider configured for passthrough (NoProvidersConfigured)",
                    protocol: clientProtocol
                ))
            }
            return .forward(request: request, target: target, protocol: clientProtocol)
        case .anthropicMessages, .openAIResponses, .openAIChatCompletions:
            guard let tool = clientProtocol.modelIDTool else {
                return .respond(Self.jsonResponse(statusCode: 404, body: ["error": "not_found"]))
            }
            // 无 model 字段或体非 JSON → 按空模型名解析（命中 .plain → 默认那家），体原样转发。
            let model = AggregationRequestParser.model(from: request.body) ?? ""
            switch resolver.resolve(tool: tool, model: model) {
            case .plain(let target):
                return .forward(request: request, target: target, protocol: clientProtocol)
            case .hit(let target, let upstreamModel):
                return .forward(
                    request: Self.requestWithModel(request, model: upstreamModel),
                    target: target,
                    protocol: clientProtocol
                )
            case .miss(let miss):
                return .respond(Self.missResponse(
                    statusCode: 400,
                    message: miss.message(model: model),
                    protocol: clientProtocol
                ))
            }
        }
    }

    // MARK: - 聚合式搬运（仅供单测/冒烟）

    /// `dispatch` + 完成式 forward 的聚合形态。转发失败 → 502 + 对应协议信封。
    func handle(_ request: AggregationHTTPRequest) -> AggregationHTTPResponse {
        switch dispatch(request) {
        case .respond(let response):
            return response
        case .forward(let forwarded, let target, let clientProtocol):
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<AggregationHTTPResponse, Error>?
            forwarder.forward(forwarded, to: target, protocol: clientProtocol) { result in
                outcome = result
                semaphore.signal()
            }
            semaphore.wait()
            switch outcome {
            case .success(let response)?:
                // 上游结果（含非 2xx）原样返回，不改状态码、不改体。
                return response
            case .failure(let error)?:
                return Self.missResponse(
                    statusCode: 502,
                    message: error.localizedDescription,
                    protocol: clientProtocol
                )
            case nil:
                return Self.missResponse(
                    statusCode: 502,
                    message: "upstream unreachable",
                    protocol: clientProtocol
                )
            }
        }
    }

    // MARK: - NWListener 数据面（生产路径）

    /// 每连接一个独立状态机：收字节 → 解析头 → 按 content-length 收体 → 分派 → 应答/流式转发。
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        receiveMore(on: connection, state: ConnectionState())
    }

    /// 单连接的收取状态（buffer / 已解析头 / 体起始偏移）。
    private final class ConnectionState {
        var buffer = Data()
        var head: AggregationRequestHead?
        var bodyStart = 0
    }

    private func receiveMore(on connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            if let data { state.buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            guard let self else {
                connection.cancel()
                return
            }
            // 1) 头未收全 → 继续收（防御：超过 1MB 还没有头，或客户端已断 → 关连接）。
            if state.head == nil {
                guard let head = AggregationRequestParser.parseHead(state.buffer) else {
                    if state.buffer.count > 1_048_576 || isComplete {
                        connection.cancel()
                    } else {
                        self.receiveMore(on: connection, state: state)
                    }
                    return
                }
                state.head = head
                guard let terminator = state.buffer.range(
                    of: Data(AggregationRequestParser.headerTerminator.utf8)
                ) else {
                    connection.cancel()
                    return
                }
                state.bodyStart = terminator.upperBound
                // 声明体量超限 → 413 并关连接（不读 body）。
                if head.contentLength > AggregationURLSessionForwarder.defaultBodyLimit {
                    self.writeResponse(Self.payloadTooLargeResponse(), on: connection) {
                        connection.cancel()
                    }
                    return
                }
            }
            // 2) body 未收满 → 继续收（客户端断了 → 关连接）。
            guard let head = state.head else {
                self.receiveMore(on: connection, state: state)
                return
            }
            let bodyLength = state.buffer.count - state.bodyStart
            if bodyLength < head.contentLength {
                if isComplete {
                    connection.cancel()
                    return
                }
                self.receiveMore(on: connection, state: state)
                return
            }
            // 3) 组请求并分派。
            let request = AggregationHTTPRequest(
                head: head,
                body: state.buffer.suffix(from: state.bodyStart)
            )
            self.dispatchAndWrite(request, on: connection)
        }
    }

    private func dispatchAndWrite(_ request: AggregationHTTPRequest, on connection: NWConnection) {
        switch dispatch(request) {
        case .respond(let response):
            // 不做 keep-alive 复用：每个请求一条连接，响应恒带 Connection: close。
            writeResponse(response, on: connection) {
                connection.cancel()
            }
        case .forward(let forwarded, let target, let clientProtocol):
            // 首块前写状态行 + 转发头（剔除 content-length/content-encoding，标 Connection: close），
            // onChunk 逐块写 socket，onComplete 关闭连接（close-delimited，SSE 以连接关闭为结束边界）。
            //
            // 关闭前必须等已排队的 send 全部写出：`cancel()` 会丢弃尚未发出的数据，
            // 最后一块通常含 `response.completed`；丢掉后 Codex 报
            // 「stream closed before response.completed」并触发 1/5 重连。
            let drain = AggregationStreamDrain()
            var headWritten = false
            forwarder.stream(
                request: forwarded,
                to: target,
                protocol: clientProtocol,
                onHead: { [weak self] statusCode, headers in
                    guard let self else { return }
                    drain.beginSend()
                    self.writeForwardHead(statusCode: statusCode, headers: headers, on: connection) {
                        if drain.endSend() { connection.cancel() }
                    }
                    headWritten = true
                },
                onChunk: { chunk in
                    drain.beginSend()
                    connection.send(content: chunk, completion: .contentProcessed { _ in
                        if drain.endSend() { connection.cancel() }
                    })
                },
                onComplete: { [weak self] _ in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    if headWritten {
                        if drain.finish() { connection.cancel() }
                        // 兜底：send 完成回调异常缺失时不得悬挂客户端连接。
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            connection.cancel()
                        }
                    } else {
                        // 上游不可达/构造失败：还没写任何字节 → 补 502 信封。
                        self.writeResponse(
                            Self.missResponse(statusCode: 502, message: "upstream unreachable", protocol: clientProtocol),
                            on: connection
                        ) {
                            connection.cancel()
                        }
                    }
                }
            )
        }
    }

    /// 本地应答：状态行 + 头（含 Content-Length）+ 体。恒带 Connection: close。
    private func writeResponse(
        _ response: AggregationHTTPResponse,
        on connection: NWConnection,
        completion: @escaping () -> Void
    ) {
        var payload = Data()
        payload.append(Data("HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(response.statusCode))\r\n".utf8))
        var hasContentLength = false
        for (key, value) in response.headers {
            payload.append(Data("\(key): \(value)\r\n".utf8))
            if key.lowercased() == "content-length" { hasContentLength = true }
        }
        if !hasContentLength {
            payload.append(Data("Content-Length: \(response.body.count)\r\n".utf8))
        }
        payload.append(Data("Connection: close\r\n\r\n".utf8))
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in completion() })
    }

    /// 转发响应头（首块前写）：状态行 + 转发头 + Connection: close；不带 Content-Length（close-delimited）。
    private func writeForwardHead(
        statusCode: Int,
        headers: [String: String],
        on connection: NWConnection,
        completion: @escaping () -> Void = {}
    ) {
        var payload = Data()
        payload.append(Data("HTTP/1.1 \(statusCode) \(Self.reasonPhrase(statusCode))\r\n".utf8))
        for (key, value) in headers {
            payload.append(Data("\(key): \(value)\r\n".utf8))
        }
        payload.append(Data("Connection: close\r\n\r\n".utf8))
        connection.send(content: payload, completion: .contentProcessed { _ in completion() })
    }

    private static func reasonPhrase(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 426: return "Upgrade Required"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    // MARK: - private

    /// 命中改写：体里 `model` 换成上游名（JSON 全量重序列化——上游对键序不敏感）。
    /// 已知代价：内存峰值约 2×body；极端数值（超大整数/非规范浮点）往返可能变形。
    private static func requestWithModel(_ request: AggregationHTTPRequest, model: String) -> AggregationHTTPRequest {
        var body = request.body
        if var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            object["model"] = model
            if let rewritten = try? JSONSerialization.data(withJSONObject: object) {
                body = rewritten
            }
        }
        // content-length 随新体校正（头字典里的 content-length 由 forwarder 剔除重算）。
        let head = AggregationRequestHead(
            method: request.head.method,
            path: request.head.path,
            query: request.head.query,
            headers: request.head.headers,
            contentLength: body.count
        )
        return AggregationHTTPRequest(head: head, body: body)
    }

    /// miss/错误信封：Anthropic 形状与 OpenAI 形状（SPEC 6.6）。
    private static func missResponse(
        statusCode: Int,
        message: String,
        protocol: AggregationClientProtocol
    ) -> AggregationHTTPResponse {
        let body: [String: Any]
        switch `protocol` {
        case .anthropicMessages:
            body = ["type": "error", "error": ["type": "invalid_request_error", "message": message]]
        // 透明端点是 Codex 形状的端点（凭证头同口径），错误信封也按 OpenAI 形状给。
        case .openAIResponses, .openAIChatCompletions, .codexPassthrough:
            body = ["error": ["message": message, "type": "invalid_request_error",
                              "param": "model", "code": "model_not_found"]]
        case .modelDiscovery, .health, .websocketProbe, .unsupported:
            body = ["error": message]
        }
        return jsonResponse(statusCode: statusCode, body: body)
    }

    private static func payloadTooLargeResponse() -> AggregationHTTPResponse {
        jsonResponse(statusCode: 413, body: ["error": "request body too large"])
    }

    private static func jsonResponse(statusCode: Int, body: [String: Any]) -> AggregationHTTPResponse {
        jsonDataResponse(
            statusCode: statusCode,
            body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        )
    }

    private static func jsonDataResponse(statusCode: Int, body: Data) -> AggregationHTTPResponse {
        AggregationHTTPResponse(
            statusCode: statusCode,
            headers: ["content-type": "application/json"],
            body: body
        )
    }

    /// OpenAI 形状的模型列表（Codex 可达性检查用）。
    private static func openAIModelListBody(published: [AggregationPublishedModel]) -> Data {
        let root: [String: Any] = [
            "object": "list",
            "data": published.map { model in
                ["id": model.id, "object": "model", "created": 0, "owned_by": "omniforge"]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}

/// 流式写回排空状态：等所有已排队 send 写出后再关闭客户端连接。
///
/// `NWConnection.cancel()` 会丢弃尚未发出的数据；直接关闭可能丢掉最后一块
/// `response.completed`，Codex 因此报「stream closed before response.completed」并重连。
/// `onChunk` 与 send 完成回调来自不同队列，计数用锁保护。
/// 用 internal 可见性以便单测覆盖排空时序。
final class AggregationStreamDrain {
    private let lock = NSLock()
    private var pendingSends = 0
    private var upstreamFinished = false

    func beginSend() {
        lock.lock()
        pendingSends += 1
        lock.unlock()
    }

    /// 一次 send 完成；返回 true 表示可以关闭连接。
    func endSend() -> Bool {
        lock.lock()
        pendingSends -= 1
        let shouldClose = upstreamFinished && pendingSends == 0
        lock.unlock()
        return shouldClose
    }

    /// 上游已结束；返回 true 表示可以立即关闭（无在途发送）。
    func finish() -> Bool {
        lock.lock()
        upstreamFinished = true
        let shouldClose = pendingSends == 0
        lock.unlock()
        return shouldClose
    }
}
