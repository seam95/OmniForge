import Foundation

/// 上游请求构造 — base 归一化、URL 拼接、凭证头重写。
/// 纯函数，无 I/O；网络搬运在 `AggregationURLSessionForwarder`（Task 14）。
enum AggregationUpstream {
    /// 逐跳头：由 URLSession 依连接管理，透传给上游只会添乱（长度对不上会让客户端截断）。
    private static let strippedHeaders: Set<String> = ["host", "content-length", "accept-encoding"]

    /// Codex 客户端指纹头：会话/账号身份与客户端版本信息，只能发往官方上游。
    /// 清单对齐 cc-switch `forwarder.rs:3581-3604`（2026-10-19 核对）。
    private static let codexIdentityHeaders: Set<String> = [
        "originator", "session_id", "session-id", "thread-id", "conversation_id",
        "chatgpt-account-id", "x-client-request-id", "openai-beta",
        "openai-organization", "openai-project", "version",
    ]

    /// Codex 客户端指纹头判定（精确名 + 前缀族）。第三方上游不该看到会话/账号身份。
    private static func isCodexClientFingerprintHeader(_ key: String) -> Bool {
        codexIdentityHeaders.contains(key)
            || key.hasPrefix("x-stainless-")
            || key.hasPrefix("x-codex-")
            || key.hasPrefix("x-oai-")
            || key.hasPrefix("x-openai-")
            || key.hasPrefix("x-responsesapi-")
    }

    /// 第三方目标要剥 Codex 指纹头；native Responses 上游保留协议标记
    /// `x-codex-beta-features`（部分网关靠它识别 Codex 协议，缺了会拒）。
    /// 官方目标（`passthroughAuthorization`）一个字节都不动：OAuth 请求本来就带这些头。
    private static func shouldStripCodexFingerprintHeader(
        _ key: String,
        protocol: AggregationClientProtocol,
        passthroughAuthorization: Bool
    ) -> Bool {
        guard !passthroughAuthorization, isCodexClientFingerprintHeader(key) else { return false }
        if key == "x-codex-beta-features", `protocol` == .openAIResponses {
            return false
        }
        return true
    }

    /// Claude Code 客户端 beta：Anthropic 形状转发时确保存在，否则认不出的上游会拒。
    private static let claudeCodeBeta = "claude-code-20250219"

    /// Anthropic Messages API 版本：缺失时补默认值。
    private static let defaultAnthropicVersion = "2023-06-01"

    /// ChatGPT 登录（Codex 用 auth.json 的 OAuth 凭证）的推理后端。
    /// **不是** `https://api.openai.com/v1`：后者只认 `sk-` API key，把 OAuth
    /// access token 发过去只会 401（2026-10-19 实测 `Unknown error`）。
    /// 对齐 codex-rs `CHATGPT_CODEX_BASE_URL` 与 cc-switch 的官方账号上游。
    /// 官方目标构造 `AggregationProxyTarget` 时用它覆盖 profile 里给人看的官方域。
    static let officialOAuthBaseURL = "https://chatgpt.com/backend-api/codex"

    /// ChatGPT Codex 后端的端点不带版本段（`/responses`，不是 `/v1/responses`）。
    private static func isChatGPTBackendBase(_ normalizedBase: String) -> Bool {
        normalizedBase.hasSuffix("/backend-api/codex")
    }

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

    /// Claude 客户端头补全（cc-switch `forwarder.rs:2363-2382`、`2629-2635`）。
    /// - `anthropic-beta`：必含 `claudeCodeBeta`——已含（逗号分隔的某一项）则原样保留；
    ///   否则**前置**逗号连接，其余 beta 原样保留（不是完整去重）。
    /// - `anthropic-version`：仅在缺失时补 `defaultAnthropicVersion`，已有值绝不覆盖。
    private static func ensureClaudeClientHeaders(_ headers: inout [String: String]) {
        if let beta = headers["anthropic-beta"] {
            let hasClaudeCode = beta.split(separator: ",")
                .contains { $0.trimmingCharacters(in: .whitespaces) == claudeCodeBeta }
            if !hasClaudeCode {
                headers["anthropic-beta"] = "\(claudeCodeBeta),\(beta)"
            }
        } else {
            headers["anthropic-beta"] = claudeCodeBeta
        }
        if headers["anthropic-version"] == nil {
            headers["anthropic-version"] = defaultAnthropicVersion
        }
    }

    /// 上游 URL = 归一化 base + 客户端路径（路径缺 `/` 前缀时补上）。
    /// ChatGPT Codex 后端特例：客户端按本地代理 base（`.../v1`）发来 `/v1/responses`，
    /// 但该后端的端点是 `/responses`——不剥版本段会打到不存在的 `/v1/responses`。
    static func upstreamURL(base: String, clientPath: String) -> URL? {
        let normalized = normalizedBase(base)
        var path = clientPath.hasPrefix("/") ? clientPath : "/" + clientPath
        if isChatGPTBackendBase(normalized), path.hasPrefix("/v1/") {
            path = String(path.dropFirst("/v1".count))
        }
        return URL(string: normalized + path)
    }

    /// 请求头重写：剔逐跳头；按协议形状把占位凭证换成真实凭证。
    /// - `passthroughAuthorization`：官方目标为真 —— 客户端的凭证头（`authorization` / `x-api-key`）
    ///   原样透传，一个字节都不换（官方账号走 OAuth `auth.json`，没有静态 token 可换；
    ///   拿空串覆盖只会把客户端自己的有效凭证打成 401）。只压掉「凭证替换」这一步：
    ///   逐跳头照剔、Claude 客户端头照补（cc-switch `forwarder.rs:2462-2467`）。
    /// - 第三方目标：额外剥掉 Codex 客户端指纹头（会话/账号身份只发官方），
    ///   native Responses 上游保留 `x-codex-beta-features`（cc-switch `forwarder.rs:2503-2510`）。
    /// - Anthropic 形状：`x-api-key` 换成本体；客户端若走 `authorization` 则保留原 Scheme 只换本体。
    ///   另补 Claude 客户端头（`anthropic-beta` 含 `claude-code-20250219`、`anthropic-version` 缺失补默认值）。
    /// - OpenAI 形状：`authorization` 恒设为 `Bearer <credential>`；不加 Claude 头（cc-switch 只对 Anthropic 上游补）。
    static func rewrittenHeaders(
        _ headers: [String: String],
        credential: String,
        protocol: AggregationClientProtocol,
        passthroughAuthorization: Bool = false
    ) -> [String: String] {
        var rewritten = headers
        for key in strippedHeaders {
            rewritten.removeValue(forKey: key)
        }
        for key in Array(rewritten.keys) {
            if shouldStripCodexFingerprintHeader(
                key.lowercased(), protocol: `protocol`, passthroughAuthorization: passthroughAuthorization
            ) {
                rewritten.removeValue(forKey: key)
            }
        }
        switch `protocol` {
        case .anthropicMessages:
            if !passthroughAuthorization {
                if rewritten["x-api-key"] != nil {
                    rewritten["x-api-key"] = credential
                } else if let authorization = rewritten["authorization"] {
                    rewritten["authorization"] = authorization.hasPrefix("Bearer ")
                        ? "Bearer \(credential)"
                        : credential
                }
            }
            ensureClaudeClientHeaders(&rewritten)
        case .openAIResponses, .openAIChatCompletions, .codexPassthrough:
            if !passthroughAuthorization {
                rewritten["authorization"] = "Bearer \(credential)"
            }
        case .modelDiscovery, .health, .websocketProbe, .unsupported:
            break // 本地应答的形状，不向上游转发
        }
        return rewritten
    }
}
