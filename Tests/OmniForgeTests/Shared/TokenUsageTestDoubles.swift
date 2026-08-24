import Foundation
import Combine
@testable import OmniForge

/// URLProtocol 桩 — 拦截 ProviderAPIClient 等 URLSession 请求并返回固定响应。
/// 仅安全测试用；生产路径不引用。
final class URLProtocolStub: URLProtocol {    /// 待返回的响应（状态码 + 头 + 体）；并发测试各自设置。
    static var stub: Stub?
    /// 按请求精确编排的响应器（多请求串行场景：刷新/wham/兄弟端点）；优先于 `stub`。
    static var handler: ((URLRequest) -> Stub)?
    /// 已处理的请求记录（断言调用序/计数）。
    private(set) static var recordedRequests: [URLRequest] = []
    /// 已处理请求的请求体（顺序对应 recordedRequests）。
    private(set) static var recordedBodies: [Data] = []

    struct Stub {
        var statusCode: Int
        var headers: [String: String] = [:]
        var data: Data = Data()
        /// 非 nil 时直接抛错（模拟断网）。
        var error: Error?
    }

    static func reset() {
        stub = nil
        handler = nil
        recordedRequests = []
        recordedBodies = []
    }

    /// 读取请求体（httpBody 或尚未消费的 httpBodyStream）。
    static func requestBody(_ request: URLRequest) -> Data {
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

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        Self.recordedBodies.append(Self.requestBody(request))
        // handler 适用于多请求串行编排（不同 URL 不同响应）；未设置时回落单个 stub。
        let stub = Self.handler?(request) ?? Self.stub
        guard let stub else {
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
    /// 最近一次调用的 force 标记（验证穿透语义传递）。
    private(set) var requestedForce = false
    /// 非 nil 时挂起直到手动放行（单飞测试）。
    var gate: AsyncGate?

    init(provider: TokenUsageProvider, results: [Result<ProviderUsageLimits?, Error>]) {
        self.provider = provider
        self.results = results
    }

    func fetchLimits(force: Bool) async throws -> ProviderUsageLimits? {
        callCount += 1
        requestedForce = force
        if let gate {
            await gate.wait()
        }
        let result = results[min(callCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 测试用限额缓存替身 — 可编排内存/冷却/last-good 结果并记录写入。
final class FakeLimitsCache: LimitsCaching {
    var memorySnapshotResult: ProviderUsageLimits?
    var lastGoodSnapshotResult: ProviderUsageLimits?
    var cooldownResult: Date?
    /// 每次 storeSuccess 追加，便于断言「落缓存」。
    private(set) var storedSuccess: [TokenUsageProvider: [ProviderUsageLimits]] = [:]
    private(set) var storedRateLimits: [TokenUsageProvider: [Date]] = [:]
    private(set) var clearedCooldowns = Set<TokenUsageProvider>()
    private(set) var clearedProviders = Set<TokenUsageProvider>()

    func memorySnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits? { memorySnapshotResult }

    func lastGoodSnapshot(for provider: TokenUsageProvider) -> ProviderUsageLimits? { lastGoodSnapshotResult }

    func storeSuccess(_ limits: ProviderUsageLimits) {
        storedSuccess[limits.provider, default: []].append(limits)
        // 镜像真实缓存：成功取数后解除冷却。
        clearedCooldowns.insert(limits.provider)
    }

    func storeNotConfigured(_ provider: TokenUsageProvider) {
        clearedProviders.insert(provider)
    }

    func storeRateLimit(for provider: TokenUsageProvider, retryAt: Date) {
        storedRateLimits[provider, default: []].append(retryAt)
    }

    func cooldown(for provider: TokenUsageProvider) -> Date? { cooldownResult }

    func clearCooldown(for provider: TokenUsageProvider) {
        clearedCooldowns.insert(provider)
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

/// 测试用 Codex 凭证替身 — 编排 auth.json 读取结果并记录调用次数。
final class FakeCodexCredentials: CodexCredentialReading {
    /// 每次调用按序出队；耗尽后重复最后一个。nil 表示「未配置」。
    var results: [Result<CodexAuthBundle?, Error>] = [.success(nil)]
    private(set) var readCount = 0

    init(bundle: CodexAuthBundle? = nil) {
        if let bundle {
            results = [.success(bundle)]
        }
    }

    func readBundle() throws -> CodexAuthBundle? {
        readCount += 1
        let result = results[min(readCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 测试用 Codex 刷新替身 — 记录调用并返回可编排结果。
final class FakeCodexTokenRefresher: CodexTokenRefreshing {
    var results: [Result<CodexRefreshedTokens, Error>] = [.success(
        CodexRefreshedTokens(accessToken: "refreshed-token", refreshToken: "rotated-refresh", idToken: nil)
    )]
    private(set) var callCount = 0
    private(set) var lastRefreshToken: String?

    func refresh(refreshToken: String) async throws -> CodexRefreshedTokens {
        callCount += 1
        lastRefreshToken = refreshToken
        let result = results[min(callCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 测试用 Kimi 凭证替身 — 编排 kimi-code.json 读取结果。
final class FakeKimiCredentials: KimiCredentialReading {
    /// 每次调用按序出队；耗尽后重复最后一个。nil 表示「未配置」。
    var results: [Result<KimiAuthBundle?, Error>] = [.success(nil)]
    private(set) var readCount = 0

    init(bundle: KimiAuthBundle? = nil) {
        if let bundle {
            results = [.success(bundle)]
        }
    }

    func readBundle() throws -> KimiAuthBundle? {
        readCount += 1
        let result = results[min(readCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 测试用 Kimi 刷新替身 — 记录调用并返回可编排结果。
final class FakeKimiTokenRefresher: KimiTokenRefreshing {
    var results: [Result<KimiRefreshedTokens, Error>] = [.success(
        KimiRefreshedTokens(accessToken: "refreshed-token", refreshToken: "rotated-refresh", expiresIn: 2880, scope: "kimi-code", tokenType: "Bearer")
    )]
    private(set) var callCount = 0
    private(set) var lastRefreshToken: String?

    func refresh(refreshToken: String) async throws -> KimiRefreshedTokens {
        callCount += 1
        lastRefreshToken = refreshToken
        let result = results[min(callCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 测试用 Cursor 凭证替身 — 编排 state.vscdb 读取结果（cookie 由 reader 拼装，替身直接携带）。
final class FakeCursorCredentials: CursorCredentialReading {
    /// 每次调用按序出队；耗尽后重复最后一个。nil 表示「未配置」。
    var results: [Result<CursorAuthBundle?, Error>] = [.success(nil)]
    private(set) var readCount = 0

    init(bundle: CursorAuthBundle? = nil) {
        if let bundle {
            results = [.success(bundle)]
        }
    }

    func readBundle() throws -> CursorAuthBundle? {
        readCount += 1
        let result = results[min(readCount - 1, results.count - 1)]
        return try result.get()
    }
}

/// 测试用 Cursor 云端 CSV 拉取替身 — 记录 cookie 并返回可编排 CSV 文本。
final class FakeCursorCSVFetcher: CursorCSVFetching {
    /// 每次调用按序出队；耗尽后重复最后一个。
    var results: [Result<String, Error>] = [.success("")]
    private(set) var callCount = 0
    private(set) var lastCookie: String?

    func fetchUsageCSV(cookie: String) async throws -> String {
        callCount += 1
        lastCookie = cookie
        let result = results[min(callCount - 1, results.count - 1)]
        return try result.get()
    }
}

// MARK: - 共享测试辅助

extension Data {
    /// 解析 application/x-www-form-urlencoded 请求体（Gemini/Kimi 刷新断言共用）。
    func dictionaryFromFormURLEncoded() -> [String: String]? {
        guard let string = String(data: self, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }
}

// MARK: - DeepSeek 余额替身

/// 测试用 DeepSeek API Key 替身 — 内存存储，记录调用。
final class FakeDeepSeekKeyStore: DeepSeekAPIKeyStoring {
    var storedKey: String?
    var readError: Error?
    var writeError: Error?
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0

    func readAPIKey() throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return storedKey
    }

    func writeAPIKey(_ apiKey: String) throws {
        writeCount += 1
        if let writeError { throw writeError }
        storedKey = apiKey
    }

    func deleteAPIKey() throws {
        deleteCount += 1
        storedKey = nil
    }
}

/// 测试用 DeepSeek 余额取数替身 — 编排放置结果并记录请求。
final class FakeDeepSeekBalanceFetcher: DeepSeekBalanceFetching {
    /// 每次调用按序出队；耗尽后重复最后一个。
    var results: [Result<[String: Any], Error>] = [.success([:])]
    private(set) var callCount = 0
    private(set) var lastURL: URL?
    private(set) var lastHeaders: [String: String]?

    func getJSON(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> [String: Any] {
        callCount += 1
        lastURL = url
        lastHeaders = headers
        let result = results[min(callCount - 1, results.count - 1)]
        return try result.get()
    }
}
