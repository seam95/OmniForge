import Foundation

/// 上游请求构造 — base 归一化、URL 拼接、凭证头重写。
/// 纯函数，无 I/O；网络搬运在 `AggregationURLSessionForwarder`（Task 14）。
enum AggregationUpstream {
    /// 逐跳头：由 URLSession 依连接管理，透传给上游只会添乱（长度对不上会让客户端截断）。
    private static let strippedHeaders: Set<String> = ["host", "content-length", "accept-encoding"]

    /// base 归一化：去尾部斜杠后剥掉**单个** `/v1` 后缀。
    /// 各家 profile 的 baseURL 形态不一（`.../api/v1`、`.../`、`.../coding`），
    /// 归一后与客户端路径直接拼接即可还原完整上游 URL。
    static func normalizedBase(_ baseURL: String) -> String {
        var base = baseURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if base.hasSuffix("/v1") {
            base = String(base.dropLast("/v1".count))
        }
        return base
    }

    /// 上游 URL = 归一化 base + 客户端路径（路径缺 `/` 前缀时补上）。
    static func upstreamURL(base: String, clientPath: String) -> URL? {
        let path = clientPath.hasPrefix("/") ? clientPath : "/" + clientPath
        return URL(string: normalizedBase(base) + path)
    }

    /// 请求头重写：剔逐跳头；按协议形状把占位凭证换成真实凭证。
    /// - Anthropic 形状：`x-api-key` 换成本体；客户端若走 `authorization` 则保留原 Scheme 只换本体。
    /// - OpenAI 形状：`authorization` 恒设为 `Bearer <credential>`。
    static func rewrittenHeaders(
        _ headers: [String: String],
        credential: String,
        protocol: AggregationClientProtocol
    ) -> [String: String] {
        var rewritten = headers
        for key in strippedHeaders {
            rewritten.removeValue(forKey: key)
        }
        switch `protocol` {
        case .anthropicMessages:
            if rewritten["x-api-key"] != nil {
                rewritten["x-api-key"] = credential
            } else if let authorization = rewritten["authorization"] {
                rewritten["authorization"] = authorization.hasPrefix("Bearer ")
                    ? "Bearer \(credential)"
                    : credential
            }
        case .openAIResponses, .openAIChatCompletions:
            rewritten["authorization"] = "Bearer \(credential)"
        case .modelDiscovery, .health, .unsupported:
            break // 本地应答的形状，不向上游转发
        }
        return rewritten
    }
}
