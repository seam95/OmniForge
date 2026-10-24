import Foundation

// MARK: - 结果

/// 供应商连通性测试结果 — 拉模型列表口径（一次验证连通 + 鉴权）。
struct ProviderConnectivityResult: Equatable {
    /// 三态判定（细分网络与鉴权，供 UI 给出针对性提示）。
    enum Outcome: Equatable {
        /// 连通且鉴权通过；携带拉到的模型 id 列表。
        case success(models: [String])
        /// 401/403 — 网络通但 Key 无效（或无权限）。
        case authRejected(status: Int)
        /// 所有候选端点都 404/405 — 连通但该供应商未实现模型列表端点。
        case endpointMissing
        /// DNS / 连接拒绝 / TLS / 超时等网络级错误（含原因描述）。
        case networkFailure(reason: String)
        /// 其他非 2xx 响应（网关 5xx 等），携带状态码与截断后的响应体。
        case serverError(status: Int, body: String)
    }

    let outcome: Outcome
    /// 从发起到最终响应的耗时（毫秒）；网络失败时也可能有值（耗尽超时）。
    let latencyMilliseconds: Int?

    var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }

    /// 成功时拉到的模型列表；非成功恒空。
    var models: [String] {
        if case .success(let models) = outcome { return models }
        return []
    }
}

// MARK: - 协议

protocol ProviderConnectivityTesting {
    func test(baseURL: String, token: String, tool: ProviderTool) async -> ProviderConnectivityResult
}

// MARK: - HTTP 边界（可注入）

/// 带 header 的 GET 边界；生产实现为 URLSession（`data(for:)`）。
protocol ProviderConnectivityHTTPRequesting {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ProviderConnectivityHTTPRequesting {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

// MARK: - 测试器

/// 供应商连通性测试器 — GET 模型列表端点（带 Key），对齐 cc-switch `model_fetch.rs`：
/// - 候选 URL 按序尝试，**仅 404/405 推进下一候选**（其他状态直接出结果）；
/// - 请求头 `Authorization: Bearer`；Claude 工具额外带 `anthropic-version`
///   （我们写入 `ANTHROPIC_AUTH_TOKEN`，Claude Code 客户端即 Bearer 形态）；
/// - 响应同时接受 OpenAI 形状 `{data:[{id}]}` 与目录形状 `{models:[{slug}]}`；
/// - 错误信息截断且绝不回显 token。
final class ProviderConnectivityTester: ProviderConnectivityTesting {
    static let timeout: TimeInterval = 15
    /// 错误响应体的截断长度（对齐 cc-switch，避免整页 HTML 404 进错误串）。
    static let errorBodyLimit = 512

    private let client: ProviderConnectivityHTTPRequesting

    init(client: ProviderConnectivityHTTPRequesting) {
        self.client = client
    }

    /// 默认 15s 超时的 ephemeral session（对齐 `PublicIPFetcher` 范式）。
    convenience init(timeout: TimeInterval = ProviderConnectivityTester.timeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.init(client: URLSession(configuration: config))
    }

    func test(baseURL: String, token: String, tool: ProviderTool) async -> ProviderConnectivityResult {
        let start = ContinuousClock.now
        // 候选为空（base 为空/无法剥出根）直接判网络失败，不发请求。
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let candidates = ProviderModelsEndpointBuilder.candidates(baseURL: baseURL) else {
            return ProviderConnectivityResult(
                outcome: .networkFailure(reason: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Base URL 为空"
                    : "无法从 Base URL 推导模型列表端点"),
                latencyMilliseconds: nil
            )
        }

        var attemptedAny = false
        for urlString in candidates {
            // 用户可能填了无 scheme 的地址；无法构成 URL 的候选直接跳过。
            guard let url = URL(string: urlString) else { continue }
            attemptedAny = true
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = Self.timeout
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if tool == .claudeCode || tool == .claudeDesktop {
                // Claude 系工具带版本头（Desktop 网关同样是 Anthropic 形状，SPEC 功能 E）。
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await client.perform(request)
            } catch {
                // 网络级错误（含超时）：按 cc-switch 口径直接失败，不换候选重试——
                // 换一个路径也到不了同一台服务器。
                return ProviderConnectivityResult(
                    outcome: .networkFailure(reason: Self.networkReason(error)),
                    latencyMilliseconds: Self.elapsedMilliseconds(since: start)
                )
            }

            guard let http = response as? HTTPURLResponse else {
                continue
            }

            switch http.statusCode {
            case 200..<300:
                // 2xx：解析模型列表；形状不符按 cc-switch 口径直接报错（不推进候选）。
                guard let models = ProviderModelsResponseDecoder.modelIDs(from: data), !models.isEmpty else {
                    return ProviderConnectivityResult(
                        outcome: .serverError(status: http.statusCode, body: "响应不是可识别的模型列表 JSON"),
                        latencyMilliseconds: Self.elapsedMilliseconds(since: start)
                    )
                }
                return ProviderConnectivityResult(
                    outcome: .success(models: models),
                    latencyMilliseconds: Self.elapsedMilliseconds(since: start)
                )
            case 401, 403:
                return ProviderConnectivityResult(
                    outcome: .authRejected(status: http.statusCode),
                    latencyMilliseconds: Self.elapsedMilliseconds(since: start)
                )
            case 404, 405:
                // 端点不存在 → 换下一个候选（其余状态直接出结果）。
                continue
            default:
                return ProviderConnectivityResult(
                    outcome: .serverError(
                        status: http.statusCode,
                        body: Self.redactedBody(data, token: token)
                    ),
                    latencyMilliseconds: Self.elapsedMilliseconds(since: start)
                )
            }
        }

        // 全部候选都无法构成合法 URL（如漏写 https://）。
        guard attemptedAny else {
            return ProviderConnectivityResult(
                outcome: .networkFailure(reason: "Base URL 不是合法地址（需以 https:// 开头）"),
                latencyMilliseconds: nil
            )
        }
        return ProviderConnectivityResult(
            outcome: .endpointMissing,
            latencyMilliseconds: Self.elapsedMilliseconds(since: start)
        )
    }

    // MARK: - private

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    /// 网络错误 → 面向用户的原因描述（不暴露底层 NSError 细节里的 URL/token）。
    private static func networkReason(_ error: Error) -> String {
        let nsError = error as NSError
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return "请求超时"
        case .cannotFindHost, .cannotConnectToHost:
            return "无法连接到服务器（域名不存在或端口不通）"
        case .dnsLookupFailed:
            return "DNS 解析失败"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "TLS 证书校验失败"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "本机网络不可用或连接中断"
        default:
            return "网络错误：\(nsError.localizedDescription)"
        }
    }

    /// 响应体 → 截断到 512 字符，且把 token 出现处替换为 `***`（绝不回显凭证）。
    private static func redactedBody(_ data: Data, token: String) -> String {
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty, text.contains(trimmedToken) {
            text = text.replacingOccurrences(of: trimmedToken, with: "***")
        }
        return String(text.prefix(errorBodyLimit))
    }
}

// MARK: - 候选 URL 构建（纯函数，可单测）

/// 模型列表端点候选构建 — 移植 cc-switch `build_models_url_candidates`：
/// 1. base 以版本段 `/v{N}` 结尾 → `{base}/models`（版本号已在路径里，不能再补 /v1，
///    否则 `.../paas/v4/v1/models` → 404）；非 `/v1` 结尾时追加 `{base}/v1/models` 兜底；
/// 2. 其他 → `{base}/v1/models`；
/// 3. base 命中已知「Anthropic 协议兼容子路径」后缀 → 追加剥离后缀后的
///    `/v1/models`、`/models` 变体（同一供应商常同时暴露两种形状的端点）；
/// 4. 去重保序。base 为空 → nil（调用方直接判失败）。
enum ProviderModelsEndpointBuilder {
    /// 已知兼容后缀，按长度降序（最长前缀优先匹配）——对齐 cc-switch `KNOWN_COMPAT_SUFFIXES`。
    static let compatSuffixes: [String] = [
        "/api/claudecode",
        "/api/anthropic",
        "/apps/anthropic",
        "/api/coding",
        "/claudecode",
        "/anthropic",
        "/coding",
        "/claude",
    ]

    /// 构建候选 URL 列表；base 为空/纯空白 → nil。
    static func candidates(baseURL: String) -> [String]? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }

        var candidates: [String] = []
        if endsWithVersionSegment(trimmed) {
            candidates.append("\(trimmed)/models")
            // 版本段非 /v1 时保留 /v1/models 兜底（正确路径已在前）。
            if !trimmed.hasSuffix("/v1") {
                candidates.append("\(trimmed)/v1/models")
            }
        } else {
            candidates.append("\(trimmed)/v1/models")
        }

        if let suffix = firstMatchingCompatSuffix(trimmed) {
            let stripped = String(trimmed.dropLast(suffix.count))
            candidates.append("\(stripped)/v1/models")
            candidates.append("\(stripped)/models")
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// 是否以版本段 `/v{N}`（N 为 1-2 位数字）结尾。
    static func endsWithVersionSegment(_ url: String) -> Bool {
        guard let lastSlash = url.lastIndex(of: "/") else { return false }
        let segment = url[url.index(after: lastSlash)...]
        guard segment.count >= 2, segment.hasPrefix("v") else { return false }
        let digits = segment.dropFirst()
        return (1...2).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }

    private static func firstMatchingCompatSuffix(_ url: String) -> String? {
        compatSuffixes.first { url.hasSuffix($0) }
    }
}

// MARK: - 响应解析（纯函数，可单测）

/// 模型列表响应解码 — 同时接受两种形状：
/// - OpenAI 兼容 `{ "data": [{ "id": "..." }] }`（`owned_by` 等多余字段忽略）；
/// - 目录形状 `{ "models": [{ "slug": "..." }] }`（智谱 `{base}/models` 即此格式）。
/// 任一形状解析出非空列表即成功；形状不符 → nil。
enum ProviderModelsResponseDecoder {
    static func modelIDs(from data: Data) -> [String]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        var ids: [String] = []
        if let rows = root["data"] as? [[String: Any]] {
            for row in rows {
                if let id = row["id"] as? String, !id.isEmpty {
                    ids.append(id)
                }
            }
        } else if let rows = root["models"] as? [[String: Any]] {
            for row in rows {
                if let slug = row["slug"] as? String, !slug.isEmpty {
                    ids.append(slug)
                }
            }
        }
        return ids.isEmpty ? nil : ids
    }
}
