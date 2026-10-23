import Foundation

/// Codex 聚合配置写入边界。
protocol AggregationCodexConfigWriting: AnyObject {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) throws
    func clearAggregation() throws
    /// 磁盘现状的契约摘要（config 文本 + 目录字节）。
    func currentContractDigest() -> String
    /// 给定投影的契约摘要（不落盘）。
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) -> String
}

/// `~/.codex/config.toml` 聚合投影 + `omniforge-stack-catalog.json` 目录写入。
/// 只动拥有键与 `[model_providers.custom]` 表；用户自建表（含内置 openai/codex）原样保留。
/// `requiresOpenAIAuth` 跟随磁盘登录状态（SPEC 6.4）——不为 true 时摘掉该键，
/// 避免登录态变化后留下误导性的登录提示。它同时决定凭证形态（见下方投影处）。
///
/// 默认那家为官方账号时**与第三方同形状**（SPEC 2026-10-17
/// 方案 B，推翻 P0-3）：同样写 custom 表指向本机代理 + 目录
/// （官方行原样取自 `models_cache.json`，成员行照常）——成员模型可用，官方请求经代理。
/// 唯一差别在凭证：官方**不写** `experimental_bearer_token`，只写
/// `requires_openai_auth`（Codex 用 auth.json 的 OAuth 凭证发请求，代理侧 passthrough
/// 透传）；第三方写占位 token 由代理替换。写占位符会让 Codex 永不带 OAuth → 401。
final class AggregationCodexConfigWriter: AggregationCodexConfigWriting {
    let configURL: URL
    let catalogURL: URL
    let modelsCacheURL: URL
    let fileManager: FileManager

    /// 占位凭证 — 代理按目标替换为真实凭证；客户端侧只见此值。
    /// 字面量与识别端（`ProviderSwitchManager.detectActive` 的聚合态判定）共用
    /// `AggregationProjectionSignature.placeholderToken`，两侧不得各写一份。

    /// 本模式写入的顶层键（`codexOwnedTopLevelKeys` 中由聚合投影负责的那部分）——
    /// 退出聚合时摘除；窗口键直连模式可能也写，故一并清理。
    /// `openai_base_url` 是 P0-3 旧官方分支写的键（现官方分支与第三方同形状不再写），
    /// 保留在清理清单内自愈旧形态残留——否则退出后残留指向已停代理的指针。
    static let writtenTopLevelKeys = [
        "model_provider",
        "model",
        "model_reasoning_effort",
        "model_catalog_json",
        "model_context_window",
        "model_auto_compact_token_limit",
        "openai_base_url",
    ]

    /// 代理契约 custom 表从默认供应商行照搬的 Codex 客户端行为键（对齐 cc-switch
    /// `codex_direct.rs` `PROXY_KEPT_CLIENT_KEYS`，#8265）。重试次数与流空闲超时是
    /// Codex 自身行为，对本地代理同样生效——行里没配的键照删不误（防上一家默认的残留）。
    private static let proxyKeptClientKeys = [
        "request_max_retries",
        "stream_max_retries",
        "stream_idle_timeout_ms",
    ]

    init(
        configURL: URL,
        catalogURL: URL,
        modelsCacheURL: URL = ProviderSwitchPaths.codexModelsCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.catalogURL = catalogURL
        self.modelsCacheURL = modelsCacheURL
        self.fileManager = fileManager
    }

    func applyAggregation(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) throws {
        let text = projectedConfigText(
            defaultProfile: defaultProfile,
            published: published,
            port: port,
            requiresOpenAIAuth: requiresOpenAIAuth
        )
        // 先写目录文件再写 config——客户端只认「目录在、配置指向它」的完整形态。
        // 官方与第三方同一形状：目录恒写（官方行 + 成员行）。
        let officialRows = officialCacheRowsIfDefault(defaultProfile: defaultProfile)
        try CodexModelCatalogStore(catalogURL: catalogURL, modelsCacheURL: modelsCacheURL, fileManager: fileManager)
            .writeAggregatedCatalog(
                defaultProfile: defaultProfile, published: published, defaultKey: defaultKey,
                officialCacheRows: officialRows
            )
        try AtomicFileWriter.write(
            text.data(using: .utf8) ?? Data(),
            to: configURL,
            fileManager: fileManager
        )
        // 自愈清理：旧版聚合目录（对齐 cc-switch 时期的文件名）已不被 config 指向，
        // 残留只会误导排查；放在投影完整落盘之后删除。
        try removeFileIfPresent(at: legacyCatalogURL)
    }

    func currentContractDigest() -> String {
        let configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let catalogData = try? Data(contentsOf: catalogURL)
        return AggregationContractDigest.codex(configText: configText, catalogData: catalogData)
    }

    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) -> String {
        // 官方行与写盘同源（同一解析函数）——摘要才能在官方/第三方默认间正确判变。
        let catalogData = CodexModelCatalogStore.aggregatedCatalogData(
            defaultProfile: defaultProfile,
            published: published,
            defaultKey: defaultKey,
            officialCacheRows: officialCacheRowsIfDefault(defaultProfile: defaultProfile)
        )
        return AggregationContractDigest.codex(
            configText: projectedConfigText(
                defaultProfile: defaultProfile,
                published: published,
                port: port,
                requiresOpenAIAuth: requiresOpenAIAuth
            ),
            catalogData: catalogData
        )
    }

    /// 投影后的 config 文本（读当前文档合并，不落盘）。
    func projectedConfigText(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) -> String {
        var document = Self.loadDocument(configURL: configURL, fileManager: fileManager)

        // 顶层：默认模型 + 思考强度 + 目录文件名（官方与第三方共用）。
        if let model = defaultProfile.codexModelList.first {
            document.setValue(model, key: "model", table: nil)
        }
        if let effort = defaultProfile.reasoningEffort, !effort.isEmpty {
            document.setValue(effort, key: "model_reasoning_effort", table: nil)
        }
        // 窗口下沉到目录行（逐行自治），顶层窗口键一律摘掉。
        document.remove(key: "model_context_window", table: nil)
        document.remove(key: "model_auto_compact_token_limit", table: nil)
        // P0-3 旧官方分支的指针键：官方现与第三方同形状，此键不再写，投影时摘残留。
        document.remove(key: "openai_base_url", table: nil)

        document.setValue("custom", key: "model_provider", table: nil)
        document.setValue(
            ProviderSwitchPaths.codexAggregationCatalogFileName,
            key: "model_catalog_json",
            table: nil
        )

        // 本机代理 provider 表（官方与第三方同形状；官方的 OAuth 凭证经
        // `requires_openai_auth` 由 Codex 附带，代理 passthrough 透传）。
        let customTable = ["model_providers", "custom"]
        document.ensureTable(path: customTable)
        document.setValue("custom", key: "name", table: customTable)
        document.setValue("http://127.0.0.1:\(port)/v1", key: "base_url", table: customTable)
        document.setValue("responses", key: "wire_api", table: customTable)
        // 凭证形态随默认那家切换（2026-10-19 401 修复）。codex-rs 的
        // `resolve_provider_auth` 先查 `experimental_bearer_token`/`api_key`，命中即采用，
        // `requires_openai_auth` 那条分支根本走不到——官方默认若也写占位符，Codex 就永不带
        // auth.json 的 OAuth，`Bearer PROXY_MANAGED` 直达官方上游，每个请求都 401。
        // 官方默认：只写 OAuth 指令，凭证由 Codex 自己附带给代理透传（对齐 cc-switch
        // `official_mirror_table`：requires_openai_auth + 无 bearer token）。
        // 第三方默认：写占位符，代理按目标替换成真实凭证。
        if requiresOpenAIAuth {
            document.remove(key: "experimental_bearer_token", table: customTable)
        } else {
            document.setValue(AggregationProjectionSignature.placeholderToken, key: "experimental_bearer_token", table: customTable)
        }
        if requiresOpenAIAuth {
            document.setBooleanValue(true, key: "requires_openai_auth", table: customTable)
        } else {
            document.remove(key: "requires_openai_auth", table: customTable)
        }

        // Codex 自身行为键从默认供应商行照搬：聚合指向 custom 表后，行里配的重试/超时
        // 不搬就全部失效（cc-switch #8265：行里配 50 次重试回落 Codex 默认 5 次）。
        let sourceTable = ["model_providers", defaultProfile.profileKey]
        for key in Self.proxyKeptClientKeys {
            if document.rawValue(key: key, table: sourceTable) != nil {
                document.copyRawValue(key: key, from: sourceTable, to: customTable)
            } else {
                document.remove(key: key, table: customTable)
            }
        }
        // 远程压缩偏好单键照搬（cc-switch #8338：丢了会退回本地摘要压缩，带搜索记录的
        // 会话可能报 response protection is unavailable）。只搬这一个能力键——其余
        // capabilities 与代理契约无关；行里没有时摘键，表内再无其他键则连表一起摘。
        let sourceCapabilities = sourceTable + ["capabilities"]
        let customCapabilities = customTable + ["capabilities"]
        if document.rawValue(key: "remote_compaction", table: sourceCapabilities) != nil {
            document.ensureTable(path: customCapabilities)
            document.copyRawValue(key: "remote_compaction", from: sourceCapabilities, to: customCapabilities)
        } else {
            document.remove(key: "remote_compaction", table: customCapabilities)
            if !document.hasEntries(in: customCapabilities) {
                document.removeTable(path: customCapabilities)
            }
        }
        return document.serialize()
    }

    func clearAggregation() throws {
        if fileManager.fileExists(atPath: configURL.path),
           let text = try? String(contentsOf: configURL, encoding: .utf8),
           var document = TOMLFile.parse(text) {
            for key in Self.writtenTopLevelKeys {
                document.remove(key: key, table: nil)
            }
            // custom 表仅当 base_url 指向本机代理时才删——避免误删用户自建的同名表。
            if Self.customTablePointsAtProxy(document) {
                document.removeTable(path: ["model_providers", "custom"])
            }
            try AtomicFileWriter.write(
                document.serialize().data(using: .utf8) ?? Data(),
                to: configURL,
                fileManager: fileManager
            )
        }
        // 目录文件清理（不存在则无事）。
        try removeCatalogFile()
        try removeFileIfPresent(at: legacyCatalogURL)
    }

    // MARK: - private

    /// 官方默认时的官方行来源：读 `models_cache.json` 原样行；非官方默认 → nil；
    /// 官方默认但缓存缺失/损坏 → 空数组（安全降级：官方行不进目录，Codex 回落内置默认）。
    private func officialCacheRowsIfDefault(defaultProfile: ProviderProfile) -> [[String: Any]]? {
        guard defaultProfile.isOfficial else { return nil }
        return CodexModelCatalogStore.officialCacheRows(modelsCacheURL: modelsCacheURL, fileManager: fileManager) ?? []
    }

    /// 旧版聚合目录文件（与现行目录同目录）。
    private var legacyCatalogURL: URL {
        catalogURL.deletingLastPathComponent()
            .appendingPathComponent(ProviderSwitchPaths.legacyCodexAggregationCatalogFileName, isDirectory: false)
    }

    /// 删掉本模式自带的目录文件（不存在则无事）。
    private func removeCatalogFile() throws {
        try removeFileIfPresent(at: catalogURL)
    }

    /// 文件存在则删除（不存在则无事）。
    private func removeFileIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// 读取并解析 config.toml；文件缺失当空文档（首次进入聚合时无配置文件可写）。
    private static func loadDocument(configURL: URL, fileManager: FileManager) -> TOMLFile {
        guard fileManager.fileExists(atPath: configURL.path),
              let text = try? String(contentsOf: configURL, encoding: .utf8),
              let document = TOMLFile.parse(text) else {
            return TOMLFile()
        }
        return document
    }

    /// `[model_providers.custom]` 的 base_url 是否指向本机代理。
    static func customTablePointsAtProxy(_ document: TOMLFile) -> Bool {
        guard let baseURL = document.stringValue(key: "base_url", table: ["model_providers", "custom"]) else {
            return false
        }
        return baseURL.hasPrefix("http://127.0.0.1:") || baseURL.hasPrefix("http://localhost:")
    }
}
