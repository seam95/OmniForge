import Foundation

// MARK: - 刷新结果与失败细分

/// 刷新成功的令牌包（id 可能轮换，缺失则保留旧值 — 见 GeminiAuthPersistence）。
struct GeminiRefreshedTokens: Equatable {
    var accessToken: String
    var idToken: String?
    /// 刷新响应的 `expires_in`（秒）；写回用于换算 expiry_date。
    var expiresIn: Double?
}

enum GeminiTokenRefreshError: Error, Equatable {
    case noRefreshToken
    /// 401/403 等不可恢复拒绝 → 上层映射为「需重新登录 gemini」。
    case refreshRejected
    case httpError(Int)
    case invalidResponse
    case network(String)
}

protocol GeminiTokenRefreshing: AnyObject {
    func refresh(refreshToken: String) async throws -> GeminiRefreshedTokens
}

// MARK: - OAuth 刷新实现

/// Gemini CLI OAuth 刷新（公开 OAuth client — installed-app 客户端无保密性，
/// 与 gemini-cli 开源仓库一致；参考 usage-limits.js:955-1019 的 fallback 常量）。
final class GeminiTokenRefresher: GeminiTokenRefreshing {
    static let endpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let oauthClientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    static let oauthClientSecret = "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"
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

    func refresh(refreshToken: String) async throws -> GeminiRefreshedTokens {
        guard !refreshToken.isEmpty else { throw GeminiTokenRefreshError.noRefreshToken }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            "client_id": Self.oauthClientID,
            "client_secret": Self.oauthClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GeminiTokenRefreshError.network(error.localizedDescription)
        } catch {
            throw GeminiTokenRefreshError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GeminiTokenRefreshError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GeminiTokenRefreshError.refreshRejected
            }
            throw GeminiTokenRefreshError.httpError(http.statusCode)
        }

        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = body["access_token"] as? String,
              !accessToken.isEmpty else {
            throw GeminiTokenRefreshError.invalidResponse
        }
        return GeminiRefreshedTokens(
            accessToken: accessToken,
            idToken: body["id_token"] as? String,
            expiresIn: (body["expires_in"] as? NSNumber)?.doubleValue
        )
    }
}
