import Foundation

// MARK: - 刷新结果与失败细分

/// 刷新成功的令牌包（refresh_token 可能轮换，缺失则保留旧值 — 见 KimiAuthPersistence）。
struct KimiRefreshedTokens: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var scope: String?
    var tokenType: String?
}

enum KimiTokenRefreshError: Error, Equatable {
    case noRefreshToken
    /// 401/403 等不可恢复拒绝 → 上层映射为「需重新登录 kimi」。
    case refreshRejected
    case httpError(Int)
    case invalidResponse
    case network(String)
}

protocol KimiTokenRefreshing: AnyObject {
    func refresh(refreshToken: String) async throws -> KimiRefreshedTokens
}

// MARK: - OAuth 刷新实现

/// Kimi Code 官方 OAuth 刷新（公开 client id + `X-Msh-Platform: kimi_cli`，与官方 CLI 一致；
/// 参考 usage-limits.js:787-829）。
final class KimiTokenRefresher: KimiTokenRefreshing {
    static let endpoint = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let oauthClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// X-Msh-Platform 头（平台标识对齐官方 CLI）。
    static let platformHeaderValue = "kimi_cli"
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

    func refresh(refreshToken: String) async throws -> KimiRefreshedTokens {
        guard !refreshToken.isEmpty else { throw KimiTokenRefreshError.noRefreshToken }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.platformHeaderValue, forHTTPHeaderField: "X-Msh-Platform")
        request.httpBody = FormURLEncoder.encode([
            "client_id": Self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw KimiTokenRefreshError.network(error.localizedDescription)
        } catch {
            throw KimiTokenRefreshError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KimiTokenRefreshError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw KimiTokenRefreshError.refreshRejected
            }
            throw KimiTokenRefreshError.httpError(http.statusCode)
        }

        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = body["access_token"] as? String,
              !accessToken.isEmpty else {
            throw KimiTokenRefreshError.invalidResponse
        }
        return KimiRefreshedTokens(
            accessToken: accessToken,
            refreshToken: (body["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresIn: (body["expires_in"] as? NSNumber)?.doubleValue,
            scope: body["scope"] as? String,
            tokenType: body["token_type"] as? String
        )
    }
}
