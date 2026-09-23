import Foundation

/// Codex `config.toml` 读写边界 — 字段所有权合并（SPEC 2.3）。
protocol CodexConfigStoring: AnyObject {
    /// 当前激活的第三方 provider：顶层 `model_provider` 指向的键 + 该表的 `base_url` 与凭证。
    /// 文件缺失 → (nil, nil, nil)；损坏 → 抛 corrupted。
    func readActiveProvider() throws -> (key: String?, baseURL: String?, token: String?)
    /// 字段所有权合并：写顶层 `model_provider` / `model`（仅当 profile 指定模型覆盖时）与
    /// `[model_providers.<key>]` 表（name / base_url / wire_api / experimental_bearer_token）。
    func applyProfile(_ profile: ProviderProfile) throws
    /// 切 Official：删除顶层 `model_provider` / `model` 拥有键；若指向非内置 provider 键则删除该表。
    func clearOverrides() throws
}

/// `~/.codex/config.toml` 读写实现（TOML 行级子集，其余键/注释原样保留）。
final class CodexConfigStore: CodexConfigStoring {
    let configURL: URL
    let fileManager: FileManager
    let catalogStore: CodexModelCatalogStoring

    /// 第三方 provider 统一走 responses wire API（Codex 0.149+ 唯一支持的 wire API）。
    static let wireAPIForThirdParty = "responses"

    init(
        configURL: URL,
        catalogStore: CodexModelCatalogStoring = CodexModelCatalogStore(),
        fileManager: FileManager = .default
    ) {
        self.configURL = configURL
        self.catalogStore = catalogStore
        self.fileManager = fileManager
    }

    func readActiveProvider() throws -> (key: String?, baseURL: String?, token: String?) {
        guard let document = try loadDocument() else { return (nil, nil, nil) }
        let key = document.stringValue(key: "model_provider", table: nil)
        let table = key.map { ["model_providers", $0] }
        let baseURL = table.flatMap { document.stringValue(key: "base_url", table: $0) }
        let token = table.flatMap { document.stringValue(key: "experimental_bearer_token", table: $0) }
        return (key, baseURL, token)
    }

    func applyProfile(_ profile: ProviderProfile) throws {
        var document = (try loadDocument()) ?? TOMLFile()
        document.setValue(profile.profileKey, key: "model_provider", table: nil)

        // 顶层 model 与模型目录投影：默认模型取列表首位，目录覆盖全部条目
        if let model = profile.codexModelList.first {
            document.setValue(model, key: "model", table: nil)
            try? catalogStore.writeCatalog(for: profile)
            document.setValue(ProviderSwitchPaths.codexModelCatalogFileName, key: "model_catalog_json", table: nil)
        } else {
            if document.stringValue(key: "model_catalog_json", table: nil) == ProviderSwitchPaths.codexModelCatalogFileName {
                document.remove(key: "model_catalog_json", table: nil)
                try? catalogStore.removeCatalog()
            }
        }

        // 思考强度（Reasoning Effort）
        if let effort = profile.reasoningEffort, !effort.isEmpty {
            document.setValue(effort, key: "model_reasoning_effort", table: nil)
        } else {
            document.remove(key: "model_reasoning_effort", table: nil)
        }

        let table = ["model_providers", profile.profileKey]
        document.ensureTable(path: table)
        document.setValue(profile.name, key: "name", table: table)
        document.setValue(profile.baseURL, key: "base_url", table: table)
        document.setValue(Self.wireAPIForThirdParty, key: "wire_api", table: table)
        document.setBooleanValue(true, key: "requires_openai_auth", table: table)
        document.setValue(profile.token, key: "experimental_bearer_token", table: table)
        try write(document)
    }

    func clearOverrides() throws {
        guard let existing = try loadDocument() else { return } // 缺失 → 无事可做
        var document = existing
        let activeKey = document.stringValue(key: "model_provider", table: nil)
        document.remove(key: "model_provider", table: nil)
        document.remove(key: "model", table: nil)
        document.remove(key: "model_reasoning_effort", table: nil)

        if document.stringValue(key: "model_catalog_json", table: nil) == ProviderSwitchPaths.codexModelCatalogFileName {
            document.remove(key: "model_catalog_json", table: nil)
            try? catalogStore.removeCatalog()
        }

        if let activeKey, !ProviderTool.codexBuiltInProviderKeys.contains(activeKey) {
            document.removeTable(path: ["model_providers", activeKey])
        }
        document.normalizeBlankLines()
        try write(document)
    }

    // MARK: - private

    /// 读取文档；文件缺失 → nil；存在但 TOML 损坏 → 抛 corrupted（不硬写）。
    private func loadDocument() throws -> TOMLFile? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8),
              let document = TOMLFile.parse(text) else {
            throw ProviderConfigFileError.corrupted(path: configURL.path)
        }
        return document
    }

    private func write(_ document: TOMLFile) throws {
        guard let data = document.serialize().data(using: .utf8) else {
            throw ProviderConfigFileError.writeFailed(path: configURL.path)
        }
        do {
            try AtomicFileWriter.write(data, to: configURL, fileManager: fileManager)
        } catch {
            throw ProviderConfigFileError.writeFailed(path: configURL.path)
        }
    }
}
