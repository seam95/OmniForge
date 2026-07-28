import Foundation

// MARK: - Protocol

protocol PublicIPFetching {
    /// 查询公网 IPv4；失败（超时 / 非 200 / 非法 body）返回 nil。
    func fetchIPv4() async -> String?
    /// 查询公网 IPv6（api64）；失败静默返回 nil。
    func fetchIPv6() async -> String?
}

// MARK: - HTTP boundary (injectable)

protocol HTTPDataFetching {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataFetching {}

// MARK: - Production fetcher

final class PublicIPFetcher: PublicIPFetching {
    static let ipv4URL = URL(string: "https://api.ipify.org")!
    static let ipv6URL = URL(string: "https://api64.ipify.org")!
    static let timeout: TimeInterval = 10

    private let client: HTTPDataFetching

    init(client: HTTPDataFetching) {
        self.client = client
    }

    /// 默认 10s 超时的 ephemeral session。
    convenience init(timeout: TimeInterval = PublicIPFetcher.timeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.init(client: URLSession(configuration: config))
    }

    func fetchIPv4() async -> String? {
        await fetchIP(from: Self.ipv4URL, preferIPv4: true)
    }

    func fetchIPv6() async -> String? {
        await fetchIP(from: Self.ipv6URL, preferIPv4: false)
    }

    private func fetchIP(from url: URL, preferIPv4: Bool) async -> String? {
        do {
            let (data, response) = try await client.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty
            else {
                return nil
            }
            return Self.validatedIP(body, preferIPv4: preferIPv4)
        } catch {
            return nil
        }
    }

    /// 仅接受看起来像 IP 的 body；非 IP 文本静默失败。
    static func validatedIP(_ raw: String, preferIPv4: Bool) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 64 else { return nil }
        // 拒绝明显非 IP（含空格 / HTML / 域名）
        if text.contains(" ") || text.contains("<") || text.contains("/") {
            return nil
        }
        if preferIPv4 {
            return isIPv4(text) ? text : nil
        }
        // api64 可能返回 v4 或 v6；两者都接受
        if isIPv4(text) || isIPv6(text) {
            return text
        }
        return nil
    }

    static func isIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    static func isIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }
}
