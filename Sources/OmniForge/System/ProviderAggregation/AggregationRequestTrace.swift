import Foundation
import os

/// 聚合请求级追踪 — 只记元数据，不记请求体、响应体、token 或凭证。
///
/// 目的：排查“为什么这个请求去了某家”“为什么切换后失败”“有没有清理 reasoning”。
/// 日志走 `os.Logger`（Console.app 可见），同时保留最近若干条供面板/测试读取。
final class AggregationRequestTrace {
    static let shared = AggregationRequestTrace()

    struct Entry: Equatable {
        let id: String
        let protocolName: String
        let requestedModel: String
        let upstreamKey: String
        let upstreamHost: String
        let statusCode: Int
        let durationMs: Int
        let requestBytes: Int
        let responseBytes: Int
        let retries: Int
        let error: String?
    }

    /// 一次转发的计时器。URLSession 回调与连接队列可能不同线程，内部加锁。
    final class Span {
        let id: String
        let protocolName: String
        let requestedModel: String
        let upstreamKey: String
        let upstreamHost: String
        let requestBytes: Int

        private let startedAt = Date()
        private let lock = NSLock()
        private var statusCode = 0
        private var responseBytes = 0
        private var retries = 0
        private var finished = false

        fileprivate init(
            id: String,
            protocolName: String,
            requestedModel: String,
            upstreamKey: String,
            upstreamHost: String,
            requestBytes: Int
        ) {
            self.id = id
            self.protocolName = protocolName
            self.requestedModel = requestedModel
            self.upstreamKey = upstreamKey
            self.upstreamHost = upstreamHost
            self.requestBytes = requestBytes
        }

        func setStatus(_ code: Int) {
            lock.lock()
            statusCode = code
            lock.unlock()
        }

        func addResponseBytes(_ count: Int) {
            lock.lock()
            responseBytes += count
            lock.unlock()
        }

        func noteRetry() {
            lock.lock()
            retries += 1
            lock.unlock()
        }

        /// 只记第一次结束；重试时旧 span 被丢弃，由新的 span 承接。
        fileprivate func finish(error: Error?) -> Entry? {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return nil
            }
            finished = true
            let entry = Entry(
                id: id,
                protocolName: protocolName,
                requestedModel: requestedModel,
                upstreamKey: upstreamKey,
                upstreamHost: upstreamHost,
                statusCode: statusCode,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                requestBytes: requestBytes,
                responseBytes: responseBytes,
                retries: retries,
                error: error?.localizedDescription
            )
            lock.unlock()
            return entry
        }
    }

    private let logger = Logger(subsystem: "com.omniforge.app", category: "ProviderAggregation")
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 200

    /// 开始一次转发追踪。请求 id 优先用 Codex 的 `x-client-request-id`。
    func begin(
        request: AggregationHTTPRequest,
        target: AggregationProxyTarget,
        protocol clientProtocol: AggregationClientProtocol
    ) -> Span {
        let requestedModel = AggregationRequestParser.model(from: request.body) ?? ""
        return Span(
            id: request.head.headers["x-client-request-id"] ?? UUID().uuidString.lowercased(),
            protocolName: Self.name(of: clientProtocol),
            requestedModel: requestedModel,
            upstreamKey: target.key,
            upstreamHost: URL(string: target.baseURL)?.host ?? "",
            requestBytes: request.body.count
        )
    }

    /// 结束并记录；重复调用无副作用。
    func finish(_ span: Span, error: Error? = nil) {
        guard let entry = span.finish(error: error) else { return }
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        logger.info("\(Self.line(entry), privacy: .public)")
    }

    /// 本地应答（miss/404/健康检查等）直接记一条，没有上游耗时。
    func recordLocal(
        request: AggregationHTTPRequest,
        protocol clientProtocol: AggregationClientProtocol,
        statusCode: Int
    ) {
        let entry = Entry(
            id: request.head.headers["x-client-request-id"] ?? UUID().uuidString.lowercased(),
            protocolName: Self.name(of: clientProtocol),
            requestedModel: AggregationRequestParser.model(from: request.body) ?? "",
            upstreamKey: "-",
            upstreamHost: "-",
            statusCode: statusCode,
            durationMs: 0,
            requestBytes: request.body.count,
            responseBytes: 0,
            retries: 0,
            error: nil
        )
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        logger.info("\(Self.line(entry), privacy: .public)")
    }

    func recent() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// 测试隔离用。
    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static func name(of clientProtocol: AggregationClientProtocol) -> String {
        switch clientProtocol {
        case .anthropicMessages: return "anthropic"
        case .claudeDesktopMessages: return "desktop-messages"
        case .claudeDesktopModelDiscovery: return "desktop-models"
        case .openAIResponses: return "responses"
        case .openAIChatCompletions: return "chat"
        case .modelDiscovery: return "models"
        case .health: return "health"
        case .websocketProbe: return "websocket-probe"
        case .codexPassthrough: return "passthrough"
        case .unsupported: return "unsupported"
        }
    }

    private static func line(_ entry: Entry) -> String {
        var fields = [
            "aggregation request",
            "id=\(entry.id)",
            "proto=\(entry.protocolName)",
            "model=\(entry.requestedModel)",
            "target=\(entry.upstreamKey)",
            "host=\(entry.upstreamHost)",
            "status=\(entry.statusCode)",
            "ms=\(entry.durationMs)",
            "req=\(entry.requestBytes)",
            "resp=\(entry.responseBytes)",
            "retries=\(entry.retries)",
        ]
        if let error = entry.error, !error.isEmpty {
            fields.append("error=\(error)")
        }
        return fields.joined(separator: " ")
    }
}
