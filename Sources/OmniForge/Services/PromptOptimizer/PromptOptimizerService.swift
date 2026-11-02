import Foundation

/// 提示词优化专用的 OpenAI 兼容 chat/completions 客户端（决策 D1：独立配置，与用量监控体系解耦）。
/// 非流式；30 秒超时；HTTP / URLError → `PromptOptimizerErrorKind` 映射。
final class PromptOptimizerService: PromptOptimizing {
    static let defaultTimeout: TimeInterval = 30

    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let session: URLSession

    init(
        baseURL: String,
        model: String,
        apiKey: String,
        timeout: TimeInterval = PromptOptimizerService.defaultTimeout,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func optimize(selectedText: String) async throws -> String {
        let messages = PromptOptimizerTemplate.compose(input: selectedText).map { message in
            ["role": message.role, "content": message.content]
        }
        return try await send(messages: messages)
    }

    /// 连通性测试（设置页「测试连接」按钮）：发送单条「你好」，返回模型回复。
    func testConnection() async throws -> String {
        try await send(messages: [["role": "user", "content": "你好"]])
    }

    /// 共享请求链路：POST `{baseURL}/chat/completions`，非流式，返回首个 choice 内容。
    private func send(messages: [[String: Any]]) async throws -> String {
        guard let url = Self.endpointURL(forBaseURL: baseURL) else {
            throw PromptOptimizerErrorKind.generic
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.defaultTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // 资源级超时到期（timeoutIntervalForResource）同样以 timedOut 抛出。
            throw error.code == .timedOut
                ? PromptOptimizerErrorKind.timeout
                : PromptOptimizerErrorKind.network
        } catch is CancellationError {
            throw PromptOptimizerErrorKind.network
        } catch {
            throw PromptOptimizerErrorKind.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw PromptOptimizerErrorKind.network
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw PromptOptimizerErrorKind.unauthorized
        default:
            throw PromptOptimizerErrorKind.generic
        }

        return try Self.content(fromResponseData: data)
    }

    // MARK: - 纯函数（可单测）

    /// 规范化 chat/completions endpoint：统一走 `SecureHTTPEndpoint` 安全校验
    /// （仅 https、回环放行 http、拒绝 query/fragment 等），未通过时返回 nil。
    /// 返回 nil 时由 `send` 映射为 `PromptOptimizerErrorKind.generic`（配置无效，
    /// 设置页提示「连接失败」，提醒用户检查 Base URL）。
    static func endpointURL(forBaseURL raw: String) -> URL? {
        try? SecureHTTPEndpoint.endpointURL(baseURL: raw, path: "/chat/completions")
    }

    /// 从 OpenAI 兼容响应提取 `choices[0].message.content`；形状异常或内容为空 → generic。
    static func content(fromResponseData data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptOptimizerErrorKind.generic
        }
        return content
    }
}
