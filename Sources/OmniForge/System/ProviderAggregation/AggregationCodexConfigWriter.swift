import Foundation

/// Codex 聚合配置写入边界。
protocol AggregationCodexConfigWriting: AnyObject {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) throws
    func clearAggregation() throws
}

/// `~/.codex/config.toml` 聚合投影 + `cc-switch-model-catalog.json` 目录写入。
/// 只动拥有键与 `[model_providers.custom]` 表；用户自建表（含内置 openai/codex）原样保留。
/// `requiresOpenAIAuth` 跟随磁盘登录状态（SPEC 6.4）——不为 true 时摘掉该键，
/// 避免登录态变化后留下误导性的登录提示。
final class AggregationCodexConfigWriter: AggregationCodexConfigWriting {
    let configURL: URL
    let catalogURL: URL
    let fileManager: FileManager

    /// 占位凭证 — 代理按目标替换为真实凭证；客户端侧只见此值（对齐 cc-switch `PROXY_MANAGED`）。
    private static let placeholderToken = "PROXY_MANAGED"

    /// 本模式写入的顶层键（`codexOwnedTopLevelKeys` 中由聚合投影负责的那部分）——
    /// 退出聚合时摘除；窗口键直连模式可能也写，故一并清理。
    private static let writtenTopLevelKeys = [
        "model_provider",
        "model",
        "model_reasoning_effort",
        "model_catalog_json",
        "model_context_window",
        "model_auto_compact_token_limit",
    ]

    init(configURL: URL, catalogURL: URL, fileManager: FileManager = .default) {
        self.configURL = configURL
        self.catalogURL = catalogURL
        self.fileManager = fileManager
    }

    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool
    ) throws {
        var document = Self.loadDocument(configURL: configURL, fileManager: fileManager)

        // 顶层：指向 custom 表 + 默认模型 + 目录文件名。
        document.setValue("custom", key: "model_provider", table: nil)
        if let model = defaultProfile.codexModelList.first {
            document.setValue(model, key: "model", table: nil)
        }
        if let effort = defaultProfile.reasoningEffort, !effort.isEmpty {
            document.setValue(effort, key: "model_reasoning_effort", table: nil)
        }
        document.setValue(
            ProviderSwitchPaths.codexAggregationCatalogFileName,
            key: "model_catalog_json",
            table: nil
        )
        // 窗口下沉到目录行（逐行自治），顶层窗口键一律摘掉。
        document.remove(key: "model_context_window", table: nil)
        document.remove(key: "model_auto_compact_token_limit", table: nil)

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

        // 先写目录文件再写 config——客户端只认「目录在、配置指向它」的完整形态。
        try CodexModelCatalogStore(catalogURL: catalogURL, fileManager: fileManager)
            .writeAggregatedCatalog(defaultProfile: defaultProfile, published: published)
        try AtomicFileWriter.write(
            document.serialize().data(using: .utf8) ?? Data(),
            to: configURL,
            fileManager: fileManager
        )
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
        if fileManager.fileExists(atPath: catalogURL.path) {
            try fileManager.removeItem(at: catalogURL)
        }
    }

    // MARK: - private

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
