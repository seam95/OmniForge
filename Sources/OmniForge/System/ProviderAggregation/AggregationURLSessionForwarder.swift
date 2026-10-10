import Foundation

/// 上游请求构造失败。
enum AggregationForwardError: Error, Equatable {
    /// base URL 与客户端路径拼不出合法 URL。
    case invalidUpstreamURL
}

/// 上游转发与 SSE 流式 — URLSession **delegate** 形态（不用 completion handler：会缓冲整个响应体）。
/// 每个进行中的转发按 `taskIdentifier` 独立登记（`Stream`），连接与目标解析不共享可变状态。
final class AggregationURLSessionForwarder: NSObject, AggregationForwarding {
    /// 请求体上限默认值（连接层超限时先拦 413，不读 body）。
    static let defaultBodyLimit = 200 * 1024 * 1024

    /// 请求体上限（连接层超限时先拦；这里只做转发侧防御，不重复读 body）。
    private let bodyLimit: Int
    private var session: URLSession!
    private let lock = NSLock()
    /// taskIdentifier → 进行中的流。只在 start（调用方线程）与 delegate 回调（串行队列）访问，加锁保护。
    private var streams: [Int: Stream] = [:]

    /// 一次进行中的转发：三个回调 + 响应头/状态码/体聚合（完成式 `forward` 用）。
    private final class Stream {
        let onHead: (Int, [String: String]) -> Void
        let onChunk: (Data) -> Void
        let onComplete: (Outcome) -> Void

        init(
            onHead: @escaping (Int, [String: String]) -> Void,
            onChunk: @escaping (Data) -> Void,
            onComplete: @escaping (Outcome) -> Void
        ) {
            self.onHead = onHead
            self.onChunk = onChunk
            self.onComplete = onComplete
        }

        struct Outcome {
            var statusCode: Int
            var headers: [String: String]
            var body: Data
            var error: Error?
        }

        var statusCode = 0
        var headers: [String: String] = [:]
        var body = Data()
    }

    init(bodyLimit: Int = AggregationURLSessionForwarder.defaultBodyLimit) {
        self.bodyLimit = bodyLimit
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        // 长会话的首 token 可能很慢（大上下文/思考模型）。
        configuration.timeoutIntervalForRequest = 300
        // delegateQueue = nil → 会话自带串行队列，回调天然串行。
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - 流式（生产路径）

    /// 流式转发。`onHead` 在首块**之前**回调（Task 15 的连接层据此先写状态行与响应头）。
    func stream(
        request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol,
        onHead: @escaping (Int, [String: String]) -> Void = { _, _ in },
        onChunk: @escaping (Data) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        start(request: request, to: target, protocol: `protocol`,
              onHead: onHead,
              onChunk: onChunk) { outcome in
            onComplete(outcome.error)
        }
    }

    // MARK: - 完成式（协议承载）

    func forward(
        _ request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol,
        completion: @escaping (Result<AggregationHTTPResponse, Error>) -> Void
    ) {
        start(request: request, to: target, protocol: `protocol`,
              onHead: { _, _ in },
              onChunk: { _ in }) { outcome in
            if let error = outcome.error {
                completion(.failure(error))
            } else {
                completion(.success(AggregationHTTPResponse(
                    statusCode: outcome.statusCode,
                    headers: outcome.headers,
                    body: outcome.body
                )))
            }
        }
    }

    // MARK: - private

    private func start(
        request: AggregationHTTPRequest,
        to target: AggregationProxyTarget,
        protocol: AggregationClientProtocol,
        onHead: @escaping (Int, [String: String]) -> Void,
        onChunk: @escaping (Data) -> Void,
        onComplete: @escaping (Stream.Outcome) -> Void
    ) {
        guard request.body.count <= bodyLimit,
              let url = AggregationUpstream.upstreamURL(base: target.baseURL, clientPath: request.head.path) else {
            onComplete(Stream.Outcome(statusCode: 0, headers: [:], body: Data(), error: AggregationForwardError.invalidUpstreamURL))
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.head.method
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 300
        for (key, value) in AggregationUpstream.rewrittenHeaders(
            request.head.headers,
            credential: target.token,
            protocol: `protocol`
        ) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        streams[task.taskIdentifier] = Stream(onHead: onHead, onChunk: onChunk, onComplete: onComplete)
        lock.unlock()
        task.resume()
    }

    private func stream(for task: URLSessionTask) -> Stream? {
        lock.lock()
        defer { lock.unlock() }
        return streams[task.taskIdentifier]
    }

    private func removeStream(for task: URLSessionTask) -> Stream? {
        lock.lock()
        defer { lock.unlock() }
        return streams.removeValue(forKey: task.taskIdentifier)
    }

    /// 响应头透传：键小写化；剔除 `content-encoding` 与 `content-length`
    /// （URLSession 已自动解压；长度对不上会让客户端截断）。
    private static func forwardedHeaders(_ raw: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in raw {
            guard let key = key as? String, let value = value as? String else { continue }
            let lowered = key.lowercased()
            if lowered == "content-encoding" || lowered == "content-length" { continue }
            headers[lowered] = value
        }
        return headers
    }
}

// MARK: - URLSessionDataDelegate

extension AggregationURLSessionForwarder: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var statusCode = 0
        var headers: [String: String] = [:]
        if let httpResponse = response as? HTTPURLResponse {
            statusCode = httpResponse.statusCode
            headers = Self.forwardedHeaders(httpResponse.allHeaderFields)
        }
        let stream = stream(for: dataTask)
        stream?.statusCode = statusCode
        stream?.headers = headers
        stream?.onHead(statusCode, headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stream = stream(for: dataTask)
        stream?.body.append(data)
        stream?.onChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let stream = removeStream(for: task) else { return }
        stream.onComplete(Stream.Outcome(
            statusCode: stream.statusCode,
            headers: stream.headers,
            body: stream.body,
            error: error
        ))
    }
}
