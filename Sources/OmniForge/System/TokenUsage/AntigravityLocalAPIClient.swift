import Foundation

/// 本地 Connect-RPC 客户端抽象（测试替身可编排）。
protocol AntigravityLocalJSONPosting {
    func postJSON(
        scheme: String,
        port: Int,
        path: String,
        body: [String: Any],
        csrfToken: String?
    ) async throws -> [String: Any]
    func probePort(scheme: String, port: Int, csrfToken: String?) async -> Bool
}

/// Antigravity 本地 Connect-RPC 客户端 — 127.0.0.1 回环自签证书放行 + JSON POST。
///
/// 安全边界：仅当 host 是回环地址（127.0.0.1/localhost/::1）时跳过 TLS 校验
/// （IDE 本地服务的证书无法通过链验证，对齐 B requestLocalJson `rejectUnauthorized: false`）；
/// 非回环 host 一律走默认校验。错误映射复用 ProviderAPIClient 的语义
/// （本场景无 401/429 区分意义 → 统一 network/decoding）。
final class AntigravityLocalAPIClient: AntigravityLocalJSONPosting {
    /// Connect-RPC 端点前缀。
    static let servicePath = "/exa.language_server_pb.LanguageServerService/"

    private let session: URLSession
    private let now: () -> Date

    init(timeout: TimeInterval = 8, now: @escaping () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let delegate = LoopbackTrustDelegate()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.now = now
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// POST JSON 到本地服务端点，返回 JSON 字典；非 200 / 解析失败抛错（不区分 HTTP 语义）。
    func postJSON(
        scheme: String,
        port: Int,
        path: String,
        body: [String: Any],
        csrfToken: String?
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else {
            throw LimitError.network("Invalid local URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in [
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
        ] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let csrfToken, !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LimitError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LimitError.network("HTTP \(code)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitError.decoding("Non-object JSON from local service")
        }
        return object
    }

    /// 端口可用性探测：GetUnleashData 成功即视为工作端口。
    func probePort(scheme: String, port: Int, csrfToken: String?) async -> Bool {
        do {
            _ = try await postJSON(
                scheme: scheme,
                port: port,
                path: Self.servicePath + "GetUnleashData",
                body: AntigravityRequestBodies.unleash,
                csrfToken: csrfToken
            )
            return true
        } catch {
            return false
        }
    }
}

/// 请求体常量（对齐 B antigravityDefaultBody / antigravityUnleashBody）。
enum AntigravityRequestBodies {
    static let defaultBody: [String: Any] = [
        "metadata": [
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en",
        ],
    ]

    static let unleash: [String: Any] = [
        "context": [
            "properties": [
                "devMode": "false",
                "extensionVersion": "unknown",
                "hasAnthropicModelAccess": "true",
                "ide": "antigravity",
                "ideVersion": "unknown",
                "installationId": "omniforge",
                "language": "UNSPECIFIED",
                "os": "macos",
                "requestedModelId": "MODEL_UNSPECIFIED",
            ],
        ],
    ]
}

/// 仅对回环地址放行无效证书的 URLSession delegate。
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host.lowercased()
        guard Self.loopbackHosts.contains(host),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 回环地址：本机自签服务，跳过链验证。
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
