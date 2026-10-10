import Foundation

/// 上游转发边界（完成式）。生产实现是 `AggregationURLSessionForwarder`（Task 14）。
protocol AggregationForwarding: AnyObject {
    func forward(
        _ request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol,
        completion: @escaping (Result<AggregationHTTPResponse, Error>) -> Void
    )
}

/// 已发布模型列表边界（发现端点用；由编排层注入，Task 20 前用 stub）。
protocol AggregationProxyModelListing: AnyObject {
    func publishedModels() -> [AggregationPublishedModel]
}

/// 分派判定结果：本地应答，或（可能已改写体的）转发。
enum AggregationDispatch: Equatable {
    case respond(AggregationHTTPResponse)
    case forward(request: AggregationHTTPRequest, target: AggregationProxyTarget, protocol: AggregationClientProtocol)
}

/// 聚合代理主体 — 判定与搬运分层：`dispatch` 是同步纯函数（路由表、miss 信封、
/// 模型名改写、发现端点在此完成判定，完全可测）；`handle` 把完成式 `forward`
/// 聚合起来，**仅供单测与 Task 20 以前的冒烟**——生产路径（Task 15 的 NWListener
/// 数据面）调用 `dispatch` + Task 14 的 `stream` 流式转发，`handle` 会缓冲整个
/// 响应体，与 SSE 逐块转发的规格冲突。
final class AggregationProxy {
    private let resolver: AggregationResolving
    private let modelLister: AggregationProxyModelListing
    private let forwarder: AggregationForwarding

    init(
        resolver: AggregationResolving,
        modelLister: AggregationProxyModelListing,
        forwarder: AggregationForwarding
    ) {
        self.resolver = resolver
        self.modelLister = modelLister
        self.forwarder = forwarder
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
        case .unsupported:
            return .respond(Self.jsonResponse(statusCode: 404, body: ["error": "not_found"]))
        case .modelDiscovery:
            let published = modelLister.publishedModels()
            if AggregationModelDiscovery.isModelDiscoveryRequest(
                method: request.head.method,
                path: request.head.path,
                headers: request.head.headers,
                query: request.head.query
            ) {
                return .respond(Self.jsonDataResponse(
                    statusCode: 200,
                    body: AggregationModelDiscovery.responseBody(published: published)
                ))
            }
            // OpenAI 形状（Codex 可达性检查）。
            return .respond(Self.jsonDataResponse(
                statusCode: 200,
                body: Self.openAIModelListBody(published: published)
            ))
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
            forwarder.forward(forwarded, to: target, protocol: clientProtocol) { completion in
                outcome = completion
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
        case .openAIResponses, .openAIChatCompletions:
            body = ["error": ["message": message, "type": "invalid_request_error",
                              "param": "model", "code": "model_not_found"]]
        case .modelDiscovery, .health, .unsupported:
            body = ["error": message]
        }
        return jsonResponse(statusCode: statusCode, body: body)
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
