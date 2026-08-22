import Foundation

// MARK: - 浏览器伪装头（集中定义；网页 API 需过 Cloudflare，参考 08/cursor-config.js）

/// Cursor 网页 API 的浏览器伪装头 — 与 TokenTracker 对齐（UA / Referer / Accept）。
enum CursorBrowserHeaders {
    static let userAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
    (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
    """
    static let referer = "https://www.cursor.com/settings"

    static func headers(cookie: String, accept: String = "*/*") -> [String: String] {
        [
            "Cookie": cookie,
            "Accept": accept,
            "Referer": referer,
            "User-Agent": userAgent,
        ]
    }
}

// MARK: - 手动重定向域校验（安全红线）

/// 重定向策略（参考 08/cursor-config.js:148-171）：
/// `Location` 只允许 https 的 `cursor.com` 域（含子域，如 www.cursor.com）才跟随并转发
/// 会话 cookie；其余域一律终止并保持只发过原站一次请求，防止向站外泄露 cookie。
enum CursorRedirectPolicy {
    static let allowedHosts = ["cursor.com"]

    /// 逐域校验：https + `cursor.com` 或任意 `*.cursor.com` 子域；相对 Location 以请求 URL 解析。
    static func isValidTarget(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        guard host == "cursor.com" || host.hasSuffix(".cursor.com") else { return false }
        return true
    }

    /// Location 头 → 校验通过的目标 URL；缺头/非法格式/外域/非 https → nil（调用方终止）。
    static func validatedTarget(location: String?, baseURL: URL) -> URL? {
        guard let location, !location.isEmpty else { return nil }
        guard let url = URL(string: location, relativeTo: baseURL)?.absoluteURL else { return nil }
        return isValidTarget(url) ? url : nil
    }
}

// MARK: - Cursor 网页客户端（手动重定向 + 浏览器伪装 + 错误细分）

/// Cursor 网页 API 客户端 — 只服务 Cursor（不动其他 provider 的 URLSession 行为）。
///
/// 与 `ProviderAPIClient` 的差异（保留其 401/403 → reauth、429 → retryAt 语义）：
/// - 请求带浏览器伪装头（UA/Referer），过 Cloudflare；
/// - **手动重定向**：会话内的 URLSession 配置 `RedirectDenyingSessionDelegate`
///   禁止传输层自动跟随（防止 cookie 在未知 DOM 间自动转发）；客户端显式读
///   `Location` → `CursorRedirectPolicy` 逐域校验 → 仅 cursor.com 域（含子域）
///   才带 cookie 跟一跳；第二跳仍是 3xx → 终止。任何越界目标 → 终止且不发起站外请求。
/// - 端点随 Cursor 改版随时可能失效：解析失败由调用方降级自身（不弹错、不连坐）。
final class CursorWebAPIClient: CursorCSVFetching {
    static let defaultTimeout: TimeInterval = 30
    static let usageSummaryEndpoint = URL(string: "https://cursor.com/api/usage-summary")!
    static let usageCSVEndpoint = URL(
        string: "https://cursor.com/api/dashboard/export-usage-events-csv?strategy=tokens"
    )!

    private let session: URLSession
    /// URLSession 不持有 delegate 强引用；客户端持住才能存活。
    private let redirectDelegate: CursorRedirectDenyingSessionDelegate
    /// 测试可注入「现在」，用于 429 retry-after 换算。
    private let now: () -> Date

    init(
        timeout: TimeInterval = CursorWebAPIClient.defaultTimeout,
        now: @escaping () -> Date = { Date() },
        session: URLSession? = nil
    ) {
        self.now = now
        let delegate = CursorRedirectDenyingSessionDelegate()
        self.redirectDelegate = delegate
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    /// GET → JSON 字典；3xx 时按「仅 cursor.com 域」手动跟一跳。
    func getJSON(url: URL, headers: [String: String]) async throws -> [String: Any] {
        let (data, response) = try await perform(url: url, headers: headers)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Invalid response")
        }
        try Self.checkStatus(http, now: now())
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("Non-object JSON")
        }
        return object
    }

    /// GET → 原始文本（云端账单 CSV 用）。
    func getText(url: URL, headers: [String: String]) async throws -> String {
        let (data, response) = try await perform(url: url, headers: headers)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Invalid response")
        }
        try Self.checkStatus(http, now: now())
        guard let text = String(data: data, encoding: .utf8) else {
            throw LimitError.decoding("Non-UTF8 body")
        }
        return text
    }

    /// `CursorCSVFetching`：云端账单 CSV 拉取（浏览器头 + 手动重定向）。
    func fetchUsageCSV(cookie: String) async throws -> String {
        try await getText(
            url: Self.usageCSVEndpoint,
            headers: CursorBrowserHeaders.headers(cookie: cookie, accept: "*/*")
        )
    }

    // MARK: 内部：两跳手动重定向

    /// 请求 → 3xx 时校验 Location 后带 cookie 跟一跳；第二跳必须 2xx。
    private func perform(url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var hops = 0
        var current = url
        while true {
            let (data, response) = try await fetch(current, headers: headers)
            guard let http = response as? HTTPURLResponse,
                  [301, 302, 303, 307, 308].contains(http.statusCode) else {
                return (data, response)
            }
            if hops >= 1 {
                throw LimitError.network("Redirect loop")
            }
            guard let target = CursorRedirectPolicy.validatedTarget(
                location: http.value(forHTTPHeaderField: "Location"),
                baseURL: current
            ) else {
                // 安全红线：站外/非 https/缺 Location → 绝不回传 cookie，直接终止。
                throw LimitError.network("Untrusted redirect")
            }
            hops += 1
            current = target
        }
    }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.defaultTimeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            throw LimitError.network(error.localizedDescription)
        } catch {
            throw LimitError.network(error.localizedDescription)
        }
    }

    private static func checkStatus(_ http: HTTPURLResponse, now: Date) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LimitError.reauthRequired
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after")
            let seconds = retryAfter.flatMap(Double.init).map { min(max($0, 0), 3600) } ?? 300
            throw LimitError.rateLimited(retryAt: now.addingTimeInterval(seconds))
        default:
            throw LimitError.network("HTTP \(http.statusCode)")
        }
    }
}

/// 禁止 URLSession 传输层自动跟随重定向（只对 Cursor 客户端生效）：
/// 让 3xx 原样回到客户端，由 `CursorRedirectPolicy` 决定是否手动跟随与转发 cookie。
final class CursorRedirectDenyingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 云端账单 CSV 拉取边界（远端为 `export-usage-events-csv`；便于测试替身）。
protocol CursorCSVFetching: AnyObject {
    func fetchUsageCSV(cookie: String) async throws -> String
}
