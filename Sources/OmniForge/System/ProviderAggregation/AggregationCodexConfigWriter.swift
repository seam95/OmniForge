import Foundation

/// Codex 聚合配置写入边界。
protocol AggregationCodexConfigWriting: AnyObject {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
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
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) -> String
}

/// `~/.codex/config.toml` 聚合投影 + `cc-switch-model-catalog.json` 目录写入。
/// 只动拥有键与 `[model_providers.custom]` 表；用户自建表（含内置 openai/codex）原样保留。
/// `requiresOpenAIAuth` 跟随磁盘登录状态（SPEC 6.4）——不为 true 时摘掉该键，
/// 避免登录态变化后留下误导性的登录提示。
///
/// 默认那家为官方账号时（`defaultIsOfficial`，SPEC 3 / P0-3）换一种形状：官方登录走
/// `auth.json` OAuth、无静态 token 可替换，故不写 `custom` 表与占位 token，改指顶层
/// `openai_base_url`；同时拿不到官方模型行 → 目录整体不写（成员模型因此不进 Codex `/model`）。
///
/// `defaultKey` 是默认那家在 `AggregationKeyRegistry` 里的 key（编排层按 `toolStack.keyOf(profileID:)`
/// 取），目录按它认「哪些 published 行属于默认那家」——与 `ProviderProfile.profileKey` 是两套
/// 刻意不同的 slug 规则，不能互换（见 `CodexModelCatalogStore.aggregatedCatalogData`）。
final class AggregationCodexConfigWriter: AggregationCodexConfigWriting {
    let configURL: URL
    let catalogURL: URL
    let fileManager: FileManager

    /// 占位凭证 — 代理按目标替换为真实凭证；客户端侧只见此值（对齐 cc-switch `PROXY_MANAGED`）。
    private static let placeholderToken = "PROXY_MANAGED"

    /// 本模式写入的顶层键（`codexOwnedTopLevelKeys` 中由聚合投影负责的那部分）——
    /// 退出聚合时摘除；窗口键直连模式可能也写，故一并清理。
    /// `openai_base_url` 是官方默认分支写的键，同样在此清单内（否则官方路径退出后
    /// 残留一个指向已停代理的指针）。
    private static let writtenTopLevelKeys = [
        "model_provider",
        "model",
        "model_reasoning_effort",
        "model_catalog_json",
        "model_context_window",
        "model_auto_compact_token_limit",
        "openai_base_url",
    ]

    init(configURL: URL, catalogURL: URL, fileManager: FileManager = .default) {
        self.configURL = configURL
        self.catalogURL = catalogURL
        self.fileManager = fileManager
    }

    func applyAggregation(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool = false
    ) throws {
        let text = projectedConfigText(
            defaultProfile: defaultProfile,
            published: published,
            port: port,
            requiresOpenAIAuth: requiresOpenAIAuth,
            defaultIsOfficial: defaultIsOfficial
        )
        if !defaultIsOfficial {
            // 先写目录文件再写 config——客户端只认「目录在、配置指向它」的完整形态。
            try CodexModelCatalogStore(catalogURL: catalogURL, fileManager: fileManager)
                .writeAggregatedCatalog(defaultProfile: defaultProfile, published: published, defaultKey: defaultKey)
        }
        try AtomicFileWriter.write(
            text.data(using: .utf8) ?? Data(),
            to: configURL,
            fileManager: fileManager
        )
        if defaultIsOfficial {
            // 官方分支不写目录；config 此刻已不指向它，再删掉磁盘上残留的旧目录文件
            // （第三方→官方切换时它还在，且内容已过期）。反序（先删后写 config）会在
            // 崩溃窗口留下「指针在、文件无」的坏配置，故放在写完之后。
            try removeCatalogFile()
        }
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
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool = false
    ) -> String {
        // 官方分支不写目录 → 目录字节按「无」参与摘要，与 `currentContractDigest`
        // 读到的（文件已删）一致；否则闸门每次都判「变了」而无谓重写。
        let catalogData = defaultIsOfficial
            ? nil
            : CodexModelCatalogStore.aggregatedCatalogData(
                defaultProfile: defaultProfile,
                published: published,
                defaultKey: defaultKey
            )
        return AggregationContractDigest.codex(
            configText: projectedConfigText(
                defaultProfile: defaultProfile,
                published: published,
                port: port,
                requiresOpenAIAuth: requiresOpenAIAuth,
                defaultIsOfficial: defaultIsOfficial
            ),
            catalogData: catalogData
        )
    }

    /// 投影后的 config 文本（读当前文档合并，不落盘）。
    func projectedConfigText(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool = false
    ) -> String {
        var document = Self.loadDocument(configURL: configURL, fileManager: fileManager)

        // 顶层：默认模型 + 思考强度 + 目录文件名（两个分支共用）。
        if let model = defaultProfile.codexModelList.first {
            document.setValue(model, key: "model", table: nil)
        }
        if let effort = defaultProfile.reasoningEffort, !effort.isEmpty {
            document.setValue(effort, key: "model_reasoning_effort", table: nil)
        }
        // 窗口下沉到目录行（逐行自治），顶层窗口键一律摘掉。
        document.remove(key: "model_context_window", table: nil)
        document.remove(key: "model_auto_compact_token_limit", table: nil)

        if defaultIsOfficial {
            // 官方默认（SPEC 3 / P0-3）：登录走 auth.json OAuth，没有静态 token 可替换，
            // 故不写 custom 表与占位 token，改指顶层 openai_base_url（cc-switch codex.rs:462-467）。
            document.setValue("http://127.0.0.1:\(port)/v1", key: "openai_base_url", table: nil)
            // 拥有键语义：摘掉 provider 指向与目录指针——第三方→官方切换时磁盘上正是
            // 这两个键的旧值，留着 Codex 会绕过本机代理、继续读旧目录。
            document.remove(key: "model_provider", table: nil)
            document.remove(key: "model_catalog_json", table: nil)
            // custom 表仅当指向本机代理时才删（判据同 clearAggregation）——上轮第三方投影
            // 写的正是它；用户自建的同名表原样保留。
            if Self.customTablePointsAtProxy(document) {
                document.removeTable(path: ["model_providers", "custom"])
            }
            return document.serialize()
        }

        document.setValue("custom", key: "model_provider", table: nil)
        document.setValue(
            ProviderSwitchPaths.codexAggregationCatalogFileName,
            key: "model_catalog_json",
            table: nil
        )

        // 本机代理 provider 表。
        let customTable = ["model_providers", "custom"]
        document.ensureTable(path: customTable)
        document.setValue("custom", key: "name", table: customTable)
        document.setValue("http://127.0.0.1:\(port)/v1", key: "base_url", table: customTable)
        document.setValue("responses", key: "wire_api", table: customTable)
        document.setValue(Self.placeholderToken, key: "experimental_bearer_token", table: customTable)
        if requiresOpenAIAuth {
            document.setBooleanValue(true, key: "requires_openai_auth", table: customTable)
        } else {
            document.remove(key: "requires_openai_auth", table: customTable)
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
    }

    // MARK: - private

    /// 删掉本模式自带的目录文件（不存在则无事）。
    private func removeCatalogFile() throws {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return }
        try fileManager.removeItem(at: catalogURL)
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
    private static func customTablePointsAtProxy(_ document: TOMLFile) -> Bool {
        guard let baseURL = document.stringValue(key: "base_url", table: ["model_providers", "custom"]) else {
            return false
        }
        return baseURL.hasPrefix("http://127.0.0.1:") || baseURL.hasPrefix("http://localhost:")
    }
}
