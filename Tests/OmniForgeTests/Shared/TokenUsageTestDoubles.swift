import Foundation
import Combine
@testable import OmniForge

/// URLProtocol 桩 — 拦截 ProviderAPIClient 等 URLSession 请求并返回固定响应。
/// 仅安全测试用；生产路径不引用。
final class URLProtocolStub: URLProtocol {
    /// 待返回的响应（状态码 + 头 + 体）；并发测试各自设置。
    static var stub: Stub?

    struct Stub {
        var statusCode: Int
        var headers: [String: String] = [:]
        var data: Data = Data()
        /// 非 nil 时直接抛错（模拟断网）。
        var error: Error?
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.local")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// 构造一并发往该桩的 URLSession。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

/// 测试用 Claude 凭证替身。
final class FakeClaudeCredentials: ClaudeCredentialReading {
    var probeResult = true
    var tokenResult: Result<String?, Error> = .success("fake-token")
    var plan: String?

    func probe() -> Bool { probeResult }

    func readAccessToken() throws -> String? {
        try tokenResult.get()
    }

    func planLabel() -> String? { plan }
}

/// 测试用限额取数器替身 — 记录调用次数并返回可编排结果。
final class StubLimitsFetcher: LimitsFetching {
    let provider: TokenUsageProvider
    /// 每次调用按序出队；耗尽后重复最后一个。nil 表示「未配置」。
    var results: [Result<ProviderUsageLimits?, Error>]
    private(set) var callCount = 0
    /// 非 nil 时挂起直到手动放行（单飞测试）。
    var gate: AsyncGate?

    init(provider: TokenUsageProvider, results: [Result<ProviderUsageLimits?, Error>]) {
        self.provider = provider
        self.results = results
    }

    func fetchLimits() async throws -> ProviderUsageLimits? {
        callCount += 1
        if let gate {
            await gate.wait()
        }
        let result = results[min(callCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 挂起/放行闸门 — 控制异步测试时序。
final class AsyncGate {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }

    func open() {
        semaphore.signal()
    }
}
