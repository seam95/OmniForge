import Foundation

// MARK: - 刷新结果与失败细分

/// 刷新成功的令牌包（refresh/id 可能轮换，缺失则保留旧值 — 见 CodexAuthPersistence）。
struct CodexRefreshedTokens: Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

/// Codex token 刷新失败细分（参考 codex-token-refresh.js:58-84）。
/// expired / reused / invalidated / 未知 401 → 上层统一映射为「需重新登录 codex login」。
enum CodexTokenRefreshError: Error, Equatable {
    case noRefreshToken
    case refreshTokenExpired
    case refreshTokenReused
    case refreshTokenInvalidated
    case refreshRejected
    case httpError(Int)
    case invalidResponse
    case network(String)
}

protocol CodexTokenRefreshing: AnyObject {
    func refresh(refreshToken: String) async throws -> CodexRefreshedTokens
}

// MARK: - OAuth 刷新实现

/// Codex 官方 OAuth 刷新（公开 client id，与官方 `codex` CLI 一致 — 参考 codex-token-refresh.js:5-7）。
final class CodexTokenRefresher: CodexTokenRefreshing {
    static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// 刷新 POST 请求超时预算（对齐 ProviderAPIClient）。
    static let requestTimeout: TimeInterval = ProviderAPIClient.defaultRequestTimeout

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func refresh(refreshToken: String) async throws -> CodexRefreshedTokens {
        guard !refreshToken.isEmpty else { throw CodexTokenRefreshError.noRefreshToken }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw CodexTokenRefreshError.network(error.localizedDescription)
        } catch {
            throw CodexTokenRefreshError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexTokenRefreshError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw CodexTokenRefreshError(rejectedReason: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            }
            throw CodexTokenRefreshError.httpError(http.statusCode)
        }

        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = body["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexTokenRefreshError.invalidResponse
        }
        return CodexRefreshedTokens(
            accessToken: accessToken,
            refreshToken: (body["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            idToken: body["id_token"] as? String
        )
    }
}

private extension CodexTokenRefreshError {
    /// 401 细分：`body.error.code`（对象）→ `body.error`（字符串）→ `body.code`。
    init(rejectedReason body: [String: Any]?) {
        let rawCode: String? = {
            if let error = body?["error"] as? [String: Any], let code = error["code"] as? String {
                return code
            }
            if let error = body?["error"] as? String { return error }
            if let code = body?["code"] as? String { return code }
            return nil
        }()
        switch (rawCode ?? "").lowercased() {
        case "refresh_token_expired": self = .refreshTokenExpired
        case "refresh_token_reused": self = .refreshTokenReused
        case "refresh_token_invalidated": self = .refreshTokenInvalidated
        default: self = .refreshRejected
        }
    }
}
