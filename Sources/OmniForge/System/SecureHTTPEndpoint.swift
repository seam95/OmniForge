import Foundation

/// 端点校验失败原因：调用方自行映射为各自的错误类型，不直接暴露给界面。
enum SecureHTTPEndpointError: Error, Equatable {
    /// Base URL 为空、无法解析，或未通过安全校验（scheme / host / 组件不合规）。
    case invalidConfiguration
}

/// AI 端点安全校验与拼接的共享实现。
///
/// 设计目的：PromptOptimizer 与 Translation 两个 OpenAI 兼容客户端共用同一套
/// HTTPS 强制规则，避免任一客户端经 `http://` 明文发送 Bearer key。
///
/// 规则（自 AITranslationService 原样迁移）：
/// - 接受含 `/v1` 等前缀的 Base URL，也接受已含完整端点 path 的地址，不重复追加；
/// - 仅接受 HTTP/HTTPS；远程地址必须 HTTPS，本机回环地址允许 HTTP；
/// - 拒绝无 host / 空 host、带 user/password、query 或 fragment 的地址。
enum SecureHTTPEndpoint {
    /// 把用户填写的 Base URL 规范化为安全端点。
    ///
    /// - Parameters:
    ///   - baseURL: 用户填写的 Base URL，允许首尾空白与尾斜杠。
    ///   - path: 端点 path（如 `/chat/completions`）；base URL 已以该 path 结尾时不重复追加。
    /// - Returns: 通过全部安全校验的完整端点 URL。
    /// - Throws: `SecureHTTPEndpointError.invalidConfiguration`，校验未通过时抛出。
    static func endpointURL(baseURL: String, path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw SecureHTTPEndpointError.invalidConfiguration }

        // 已含完整端点 path 时保持原样，否则拼接一次。
        let full = base.hasSuffix(path) ? base : base + path
        guard let components = URLComponents(string: full),
              let url = components.url,
              let host = components.host,
              !host.isEmpty else {
            throw SecureHTTPEndpointError.invalidConfiguration
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw SecureHTTPEndpointError.invalidConfiguration
        }
        // 凭据、query 或 fragment 可能把密钥与参数带进日志，直接拒绝。
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw SecureHTTPEndpointError.invalidConfiguration
        }
        // 远程接口必须 HTTPS；仅回环地址允许明文 HTTP，便于本机无鉴权服务。
        if scheme == "http", !isLoopbackHost(host) {
            throw SecureHTTPEndpointError.invalidConfiguration
        }
        return url
    }

    /// 是否为回环主机名：`localhost`、`127.0.0.1`、IPv6 回环 `[::1]`。
    private static func isLoopbackHost(_ host: String) -> Bool {
        var normalized = host.lowercased()
        // URLComponents 对 IPv6 主机保留方括号。
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
    }
}
