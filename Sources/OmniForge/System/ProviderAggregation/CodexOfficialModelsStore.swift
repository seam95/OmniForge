import Foundation
import os

/// Codex 官方模型列表来源。
protocol CodexOfficialModelsProviding: AnyObject {
    /// 当前可用的官方行：优先 OmniForge 自己拉的缓存，其次 Codex 的 models_cache。
    func rows(authURL: URL, modelsCacheURL: URL) -> [[String: Any]]?
    /// 缓存缺失或过期时在后台拉取；真正拉取并写入后才回调。
    func refresh(authURL: URL, modelsCacheURL: URL, completion: @escaping () -> Void)
}

/// 主动拉取 ChatGPT Codex 官方模型列表。
///
/// 写了 `model_catalog_json` 后 Codex 只认文件里的模型，不再刷新自己的列表；官方行
/// 必须自带完整清单。来源按 cc-switch：
/// `https://chatgpt.com/backend-api/codex/models?client_version=…`，用 Codex 的
/// OAuth access token + `ChatGPT-Account-Id` 鉴权。
///
/// 缓存独立于 `~/.codex/models_cache.json`（那是 Codex 自己写的，身份/版本无法核对）。
/// 只缓存一份，键由工作区 ID + 用户 `sub` + client_version 决定；6 小时内视为新鲜。
/// 拉取失败不覆盖旧缓存，调用方继续用 models_cache 兜底。
final class CodexOfficialModelsStore: CodexOfficialModelsProviding {
    struct Context: Equatable {
        let identity: String
        let clientVersion: String
        let accessToken: String
        let accountID: String
    }

    struct FetchResponse {
        let statusCode: Int
        let data: Data
        let etag: String?
    }

    typealias Fetcher = (URLRequest) -> Result<FetchResponse, Error>

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    static let freshFor: TimeInterval = 6 * 60 * 60
    static let maxBodyBytes = 16 * 1024 * 1024

    private let cacheURL: URL
    private let fileManager: FileManager
    private let fetch: Fetcher
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.omniforge.app", category: "CodexOfficialModels")
    private let lock = NSLock()
    private var refreshing = false

    init(
        cacheURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        fetch: Fetcher? = nil
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        self.now = now
        self.fetch = fetch ?? Self.defaultFetch
    }

    func rows(authURL: URL, modelsCacheURL: URL) -> [[String: Any]]? {
        guard let context = context(authURL: authURL, modelsCacheURL: modelsCacheURL),
              let entry = readCache(),
              entry.identity == context.identity,
              entry.clientVersion == context.clientVersion,
              !entry.models.isEmpty else {
            return CodexModelCatalogStore.officialCacheRows(
                modelsCacheURL: modelsCacheURL, fileManager: fileManager
            )
        }
        return entry.models
    }

    func refresh(authURL: URL, modelsCacheURL: URL, completion: @escaping () -> Void) {
        lock.lock()
        if refreshing {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.refreshing = false
                self.lock.unlock()
            }
            guard let context = self.context(authURL: authURL, modelsCacheURL: modelsCacheURL) else {
                return
            }
            let cached = self.readCache()
            if let cached,
               cached.identity == context.identity,
               cached.clientVersion == context.clientVersion,
               self.now().timeIntervalSince1970 - cached.fetchedAt < Self.freshFor {
                return
            }
            let etag = cached.flatMap { entry in
                entry.identity == context.identity && entry.clientVersion == context.clientVersion
                    ? entry.etag : nil
            }
            guard let request = Self.request(context: context, etag: etag) else { return }
            switch self.fetch(request) {
            case .success(let response):
                self.handle(
                    response, context: context, previous: cached, modelsCacheURL: modelsCacheURL
                )
                completion()
            case .failure(let error):
                self.logger.info("fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - context

    private func context(authURL: URL, modelsCacheURL: URL) -> Context? {
        guard let authData = try? Data(contentsOf: authURL),
              let auth = (try? JSONSerialization.jsonObject(with: authData)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty,
              let sub = Self.jwtSubject(tokens["id_token"] as? String),
              let version = Self.clientVersion(modelsCacheURL: modelsCacheURL, fileManager: fileManager)
        else {
            return nil
        }
        return Context(
            identity: "\(account)|\(sub)",
            clientVersion: version,
            accessToken: access,
            accountID: account
        )
    }

    static func clientVersion(modelsCacheURL: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: modelsCacheURL.path),
              let data = try? Data(contentsOf: modelsCacheURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = root["client_version"] as? String,
              validVersion(version) else {
            return nil
        }
        return version
    }

    static func validVersion(_ version: String) -> Bool {
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        guard !core.isEmpty, version.count <= 64 else { return false }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        return parts.contains { $0.contains(where: { $0 != "0" }) }
    }

    static func jwtSubject(_ token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sub = object["sub"] as? String, !sub.isEmpty else {
            return nil
        }
        return sub
    }

    // MARK: - request / response

    private static func request(context: Context, etag: String?) -> URLRequest? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "client_version", value: context.clientVersion)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(context.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    private static func defaultFetch(_ request: URLRequest) -> Result<FetchResponse, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<FetchResponse, Error> = .failure(
            NSError(domain: "CodexOfficialModels", code: -1)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(NSError(domain: "CodexOfficialModels", code: -2))
                return
            }
            outcome = .success(FetchResponse(
                statusCode: http.statusCode,
                data: data ?? Data(),
                etag: http.value(forHTTPHeaderField: "ETag")
            ))
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        session.invalidateAndCancel()
        return outcome
    }

    private func handle(
        _ response: FetchResponse,
        context: Context,
        previous: CacheEntry?,
        modelsCacheURL: URL
    ) {
        if response.statusCode == 304 {
            guard let previous,
                  previous.identity == context.identity,
                  previous.clientVersion == context.clientVersion else {
                return
            }
            var updated = previous
            updated.fetchedAt = now().timeIntervalSince1970
            writeCache(updated)
            return
        }
        guard response.statusCode == 200,
              response.data.count <= Self.maxBodyBytes,
              let root = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              !models.isEmpty,
              models.contains(where: { ($0["visibility"] as? String) == "list" }) else {
            if response.statusCode >= 400 {
                logger.info("fetch status \(response.statusCode, privacy: .public)")
            }
            return
        }
        let fallback = CodexModelCatalogStore.officialCacheRows(
            modelsCacheURL: modelsCacheURL, fileManager: fileManager
        ) ?? []
        writeCache(CacheEntry(
            identity: context.identity,
            clientVersion: context.clientVersion,
            fetchedAt: now().timeIntervalSince1970,
            etag: response.etag,
            models: Self.normalized(models, fallback: fallback)
        ))
    }

    /// 服务端返回的是 ModelInfo；补上目录解析必需、而服务端可能省略的字段：
    /// 同 slug 的 models_cache 行优先补齐（保留官方工具形态），其余用第一条官方行兜底。
    static func normalized(_ models: [[String: Any]], fallback: [[String: Any]]) -> [[String: Any]] {
        let bySlug = Dictionary(
            fallback.compactMap { row -> (String, [String: Any])? in
                guard let slug = row["slug"] as? String else { return nil }
                return (slug, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let template = fallback.first
        return models.enumerated().compactMap { index, raw in
            guard var row = raw as [String: Any]?, let slug = row["slug"] as? String, !slug.isEmpty else {
                return nil
            }
            let sameSlug = bySlug[slug]
            if let sameSlug {
                for (key, value) in sameSlug where row[key] == nil {
                    // 不把身份/窗口带进来；同 slug 的 comp_hash 可以继承（官方压缩语义）。
                    if ["slug", "display_name", "description", "priority",
                        "context_window", "max_context_window",
                        "auto_compact_token_limit"].contains(key) {
                        continue
                    }
                    row[key] = value
                }
            }
            let skeleton = sameSlug ?? template
            if row["base_instructions"] == nil {
                if let template = (row["model_messages"] as? [String: Any])?["instructions_template"] as? String {
                    row["base_instructions"] = template
                } else if let base = sameSlug?["base_instructions"] as? String {
                    row["base_instructions"] = base
                } else {
                    row["base_instructions"] = CodexModelCatalogStore.neutralBaseInstructions
                }
            }
            row["supports_reasoning_summaries"] = row["supports_reasoning_summaries"]
                ?? skeleton?["supports_reasoning_summaries"] ?? true
            row["supports_parallel_tool_calls"] = row["supports_parallel_tool_calls"]
                ?? skeleton?["supports_parallel_tool_calls"] ?? true
            row["visibility"] = row["visibility"] ?? skeleton?["visibility"] ?? "list"
            row["supported_in_api"] = row["supported_in_api"] ?? true
            row["shell_type"] = row["shell_type"] ?? skeleton?["shell_type"] ?? "unified_exec"
            row["truncation_policy"] = row["truncation_policy"] ?? ["mode": "tokens", "limit": 10_000]
            row["input_modalities"] = row["input_modalities"] ?? ["text", "image"]
            row["priority"] = row["priority"] ?? index
            return row
        }
    }

    // MARK: - cache

    struct CacheEntry {
        let identity: String
        let clientVersion: String
        var fetchedAt: TimeInterval
        let etag: String?
        let models: [[String: Any]]
    }

    private func readCache() -> CacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let identity = root["identity"] as? String,
              let clientVersion = root["clientVersion"] as? String,
              let fetchedAt = root["fetchedAt"] as? TimeInterval,
              let models = root["models"] as? [[String: Any]] else {
            return nil
        }
        return CacheEntry(
            identity: identity,
            clientVersion: clientVersion,
            fetchedAt: fetchedAt,
            etag: root["etag"] as? String,
            models: models
        )
    }

    /// 官方 models 端点被重定向（登录页等）时不能把 Bearer token 带过去。
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private func writeCache(_ entry: CacheEntry) {
        var root: [String: Any] = [
            "identity": entry.identity,
            "clientVersion": entry.clientVersion,
            "fetchedAt": entry.fetchedAt,
            "models": entry.models,
        ]
        if let etag = entry.etag, !etag.isEmpty {
            root["etag"] = etag
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try AtomicFileWriter.write(data, to: cacheURL, fileManager: fileManager)
        } catch {
            logger.info("cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
