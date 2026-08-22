import Foundation

/// Provider 限额 API 客户端 — URLSession 薄封装，401/403 → reauth、429 → retryAt（参考 06）。
/// 单请求超时预算对齐 provider 15s（`DEFAULT_PROVIDER_TIMEOUT_MS`）。
final class ProviderAPIClient {
    static let defaultRequestTimeout: TimeInterval = 15

    private let session: URLSession
    /// 测试可注入「现在」，用于 429 retry-after 换算。
    private let now: () -> Date

    init(
        timeout: TimeInterval = ProviderAPIClient.defaultRequestTimeout,
        now: @escaping () -> Date = { Date() },
        session: URLSession? = nil
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

    /// GET 请求，返回 JSON 字典；HTTP 错误映射为 `LimitError`。
    /// - 401/403 → `.reauthRequired`（短路，调用方不回退）
    /// - 429 → `.rateLimited(retryAt:)`（retry-after 头换算，默认 5 分钟冷却）
    /// - 半私有兄弟端点可用 `timeout` 注入更短的请求级超时（如 Codex reset-credits 3s）。
    func getJSON(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = ProviderAPIClient.defaultRequestTimeout
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LimitError.network(error.localizedDescription)
        } catch {
            throw LimitError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Invalid response")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw LimitError.reauthRequired
        case 429:
            throw LimitError.rateLimited(retryAt: retryAt(from: http))
        default:
            throw LimitError.network("HTTP \(http.statusCode)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("Non-object JSON")
        }
        return object
    }

    /// 429 冷却时间：retry-after 头（秒）→ Date；无头默认 5 分钟；上限 1 小时。
    func retryAt(from response: HTTPURLResponse) -> Date {
        let retryAfter = response.value(forHTTPHeaderField: "retry-after")
        let seconds = retryAfter.flatMap(Double.init).map { min(max($0, 0), 3600) } ?? 300
        return now().addingTimeInterval(seconds)
    }
}
