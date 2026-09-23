import Foundation

// MARK: - WebID 提取工具

enum StepfunWebIDExtractor {
    static let defaultWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"

    /// 从 Oasis-Token 提取用于 oasis-webid 校验的 device_id。
    /// 服务端校验规则：请求头中的 oasis-webid 必须与 token 携带的 device_id 严格一致。
    static func webID(forToken token: String) -> String {
        let halves = token.components(separatedBy: "...")
        for half in halves.reversed() {
            if let deviceId = extractDeviceID(fromJWT: half), !deviceId.isEmpty {
                return deviceId
            }
        }
        return defaultWebID
    }

    private static func extractDeviceID(fromJWT jwt: String) -> String? {
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
        return json["device_id"] as? String
    }
}

// MARK: - 协议边界

protocol StepfunWebAPIFetching: AnyObject {
    func queryRateLimit(token: String) async throws -> [String: Any]
    func getPlanStatus(token: String) async throws -> [String: Any]?
}

// MARK: - 客户端实现

final class StepfunWebAPIClient: StepfunWebAPIFetching {
    static let rateLimitURL = URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!
    static let planStatusURL = URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus")!
    static let defaultTimeout: TimeInterval = 15

    private let session: URLSession
    private let now: () -> Date

    init(
        session: URLSession? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.defaultTimeout
            configuration.timeoutIntervalForResource = Self.defaultTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

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

    // MARK: - 私有请求方法

    private func post(url: URL, token: String) async throws -> [String: Any] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw LimitError.reauthRequired
        }

        let webID = StepfunWebIDExtractor.webID(forToken: trimmedToken)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.defaultTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("10300", forHTTPHeaderField: "oasis-appid")
        request.setValue("web", forHTTPHeaderField: "oasis-platform")
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
}
