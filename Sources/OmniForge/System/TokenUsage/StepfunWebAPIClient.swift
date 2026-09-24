import Foundation

// MARK: - WebID / token 工具

enum StepfunWebIDExtractor {
    static let defaultWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"

    /// 从 Oasis-Token 提取用于 oasis-webid 校验的 device_id。
    /// 服务端校验规则：请求头中的 oasis-webid 必须与 token 携带的 device_id 严格一致。
    /// token 为裸 JWT 或 `access...refresh` 两段拼接；device_id 在 refresh 段，回退 access 段。
    static func webID(forToken token: String) -> String {
        let halves = token.components(separatedBy: "...")
        for half in halves.reversed() {
            if let deviceId = claims(fromJWT: half)?["device_id"] as? String, !deviceId.isEmpty {
                return deviceId
            }
        }
        return defaultWebID
    }

    /// access 段（第一个 JWT）的过期时间，用于主动续期。token 为 `access...refresh` 或单段；
    /// 解析不到 exp 返回 nil（调用方按「无法判断」处理，不主动续期）。
    static func accessTokenExpiry(_ token: String) -> Date? {
        let accessHalf = token.components(separatedBy: "...").first ?? token
        guard let exp = flexibleNumber(claims(fromJWT: accessHalf)?["exp"]) else { return nil }
        guard exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// 解析 JWT payload（不校验签名）为 claims；非 JWT 返回 nil。
    static func claims(fromJWT jwt: String) -> [String: Any]? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
        // 补充 base64url padding
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        let base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func flexibleNumber(_ raw: Any?) -> TimeInterval? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return TimeInterval(i) }
        if let i64 = raw as? Int64 { return TimeInterval(i64) }
        if let s = raw as? String, let d = Double(s) { return d }
        return nil
    }
}

// MARK: - 协议边界

protocol StepfunWebAPIFetching: AnyObject {
    func queryRateLimit(token: String) async throws -> [String: Any]
    func getPlanStatus(token: String) async throws -> [String: Any]?
    /// 账号密码登录，返回 `access...refresh` 组合 token。
    @discardableResult func login(username: String, password: String) async throws -> String
    /// 以当前 token 续期，返回新的 `access...refresh` 组合 token。
    func refreshToken(token: String) async throws -> String
}

// MARK: - token 响应模型（accessToken.raw / refreshToken.raw）

private struct StepfunTokenResponse: Decodable {
    let accessToken: StepfunTokenValue?
    let refreshToken: StepfunTokenValue?
}

private struct StepfunTokenValue: Decodable {
    let raw: String
}

// MARK: - 客户端实现

final class StepfunWebAPIClient: StepfunWebAPIFetching {
    static let platformURL = URL(string: "https://platform.stepfun.com")!
    static let rateLimitURL = URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!
    static let planStatusURL = URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus")!
    static let registerDeviceURL = URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RegisterDevice")!
    static let signInURL = URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/SignInByPassword")!
    static let refreshTokenURL = URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RefreshToken")!
    static let defaultTimeout: TimeInterval = 15
    static let appID = "10300"
    /// 模拟浏览器 UA：登录/设备注册端点对非浏览器客户端可能风控。
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

    /// 用量查询会话（ephemeral：token 显式携带，无需持久 Cookie）。
    private let session: URLSession
    /// 登录流程会话（default + 共享 Cookie 存储：INGRESSCOOKIE 落 jar 作兜底）。
    private let authSession: URLSession
    private let now: () -> Date

    init(
        session: URLSession? = nil,
        authSession: URLSession? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.session = session ?? Self.makeSession(sharedCookies: false)
        self.authSession = authSession ?? Self.makeSession(sharedCookies: true)
        self.now = now
    }

    private static func makeSession(sharedCookies: Bool) -> URLSession {
        let configuration: URLSessionConfiguration
        if sharedCookies {
            configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = HTTPCookieStorage.shared
        } else {
            configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
        }
        configuration.timeoutIntervalForRequest = Self.defaultTimeout
        configuration.timeoutIntervalForResource = Self.defaultTimeout
        return URLSession(configuration: configuration)
    }

    // MARK: - 用量查询

    func queryRateLimit(token: String) async throws -> [String: Any] {
        try await post(url: Self.rateLimitURL, token: token)
    }

    func getPlanStatus(token: String) async throws -> [String: Any]? {
        do {
            return try await post(url: Self.planStatusURL, token: token)
        } catch {
            // 套餐状态接口失败时静默降级（仍可展示限额）
            return nil
        }
    }

    // MARK: - 登录 / 续期

    func login(username: String, password: String) async throws -> String {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !trimmedPass.isEmpty else {
            throw LimitError.reauthRequired
        }
        // ① 首页拿 INGRESSCOOKIE
        let ingress = try await ingressCookie()
        // ② 设备注册拿匿名 token
        let anonToken = try await registerDevice(ingressCookie: ingress)
        // ③ 账密登录拿认证 token
        return try await signInByPassword(
            username: trimmedUser,
            password: trimmedPass,
            ingressCookie: ingress,
            anonToken: anonToken
        )
    }

    func refreshToken(token: String) async throws -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw LimitError.reauthRequired }
        let webid = StepfunWebIDExtractor.webID(forToken: normalized)

        var request = URLRequest(url: Self.refreshTokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        applyBaseHeaders(to: &request)
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue(normalized, forHTTPHeaderField: "Oasis-Token")
        request.setValue("Oasis-Token=\(normalized); Oasis-Webid=\(webid)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await authSession.data(for: request)
        try ensureOK(response, data: data, context: "RefreshToken")
        guard let decoded = try? JSONDecoder().decode(StepfunTokenResponse.self, from: data),
              let access = decoded.accessToken?.raw, !access.isEmpty else {
            throw LimitError.reauthRequired
        }
        return Self.combine(access: access, refresh: decoded.refreshToken?.raw)
    }

    // MARK: - 私有：登录三步

    private func ingressCookie() async throws -> String {
        var request = URLRequest(url: Self.platformURL)
        request.httpMethod = "GET"
        applyBaseHeaders(to: &request)

        let (_, response) = try await authSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("Invalid ingress response")
        }
        if let cookie = Self.parseIngressCookie(from: http), !cookie.isEmpty {
            return cookie
        }
        // 兜底：共享 Cookie 存储（生产环境 CFNetwork 可能把 Set-Cookie 收进 jar）
        if let stored = HTTPCookieStorage.shared.cookies(for: Self.platformURL)?
            .first(where: { $0.name == "INGRESSCOOKIE" }), !stored.value.isEmpty {
            return stored.value
        }
        throw LimitError.network("Could not obtain INGRESSCOOKIE")
    }

    private func registerDevice(ingressCookie: String) async throws -> String {
        var request = URLRequest(url: Self.registerDeviceURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        applyBaseHeaders(to: &request)
        request.setValue("INGRESSCOOKIE=\(ingressCookie)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await authSession.data(for: request)
        try ensureOK(response, data: data, context: "RegisterDevice")
        guard let decoded = try? JSONDecoder().decode(StepfunTokenResponse.self, from: data),
              let access = decoded.accessToken?.raw, !access.isEmpty else {
            throw LimitError.decoding("RegisterDevice: no access token")
        }
        return Self.combine(access: access, refresh: decoded.refreshToken?.raw)
    }

    private func signInByPassword(
        username: String,
        password: String,
        ingressCookie: String,
        anonToken: String
    ) async throws -> String {
        var request = URLRequest(url: Self.signInURL)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        applyBaseHeaders(to: &request)
        let webid = StepfunWebIDExtractor.webID(forToken: anonToken)
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue(
            "Oasis-Token=\(anonToken); Oasis-Webid=\(webid); INGRESSCOOKIE=\(ingressCookie)",
            forHTTPHeaderField: "Cookie"
        )

        let (data, response) = try await authSession.data(for: request)
        try ensureOK(response, data: data, context: "SignInByPassword")
        guard let decoded = try? JSONDecoder().decode(StepfunTokenResponse.self, from: data),
              let access = decoded.accessToken?.raw, !access.isEmpty else {
            // 账号密码错误 / 被风控：拿不到 token
            throw LimitError.reauthRequired
        }
        return Self.combine(access: access, refresh: decoded.refreshToken?.raw)
    }

    // MARK: - 私有：用量请求

    private func post(url: URL, token: String) async throws -> [String: Any] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw LimitError.reauthRequired
        }

        let webID = StepfunWebIDExtractor.webID(forToken: trimmedToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyBaseHeaders(to: &request)
        request.setValue(webID, forHTTPHeaderField: "oasis-webid")
        request.setValue("Oasis-Token=\(trimmedToken); Oasis-Webid=\(webID)", forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{}".utf8)

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
            let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init).map { min(max($0, 0), 3600) } ?? 300
            throw LimitError.rateLimited(retryAt: now().addingTimeInterval(retryAfter))
        default:
            throw LimitError.network("HTTP \(http.statusCode)")
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LimitError.decoding("Non-object JSON")
        }

        // 检查业务层错误（部分情况 HTTP 200 但业务提示盗用或未登录）
        if let desc = json["desc"] as? String, desc.contains("oasis-token is embezzled") || desc.contains("auth failed") {
            throw LimitError.reauthRequired
        }

        return json
    }

    // MARK: - 私有：工具

    private func applyBaseHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.appID, forHTTPHeaderField: "oasis-appid")
        request.setValue("web", forHTTPHeaderField: "oasis-platform")
        request.setValue(StepfunWebIDExtractor.defaultWebID, forHTTPHeaderField: "oasis-webid")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.defaultTimeout
    }

    private func ensureOK(_ response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LimitError.network("\(context): invalid response")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LimitError.reauthRequired
        case 429:
            throw LimitError.rateLimited(retryAt: now().addingTimeInterval(300))
        default:
            throw LimitError.network("\(context): HTTP \(http.statusCode)")
        }
    }

    private static func combine(access: String, refresh: String?) -> String {
        guard let refresh, !refresh.isEmpty else { return access }
        return "\(access)...\(refresh)"
    }

    private static func parseIngressCookie(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard (key as? String)?.lowercased() == "set-cookie" else { continue }
            let cookieStrings: [String]
            if let single = value as? String {
                cookieStrings = [single]
            } else if let many = value as? [String] {
                cookieStrings = many
            } else {
                cookieStrings = ["\(value)"]
            }
            for cookieString in cookieStrings {
                guard let range = cookieString.range(of: "INGRESSCOOKIE=") else { continue }
                let after = cookieString[range.upperBound...]
                let valuePart = after.components(separatedBy: ";").first ?? ""
                let trimmed = valuePart.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
