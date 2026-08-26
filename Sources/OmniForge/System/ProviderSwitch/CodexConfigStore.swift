import Foundation

/// Codex `config.toml` 读写边界 — 字段所有权合并（SPEC 2.3）。
protocol CodexConfigStoring: AnyObject {
    /// 当前激活的第三方 provider：顶层 `model_provider` 指向的键 + 该表 `base_url`。
    /// 文件缺失 → (nil, nil)；损坏 → 抛 corrupted。
    func readActiveProvider() throws -> (key: String?, baseURL: String?)
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

    /// 第三方 provider 统一走 chat 风格 wire API（OpenAI 兼容端点）。
    static let wireAPIForThirdParty = "chat"

    init(configURL: URL, fileManager: FileManager = .default) {
        self.configURL = configURL
        self.fileManager = fileManager
    }

    func readActiveProvider() throws -> (key: String?, baseURL: String?) {
        guard let document = try loadDocument() else { return (nil, nil) }
        let key = document.stringValue(key: "model_provider", table: nil)
        let baseURL = key.flatMap {
            document.stringValue(key: "base_url", table: ["model_providers", $0])
        }
        return (key, baseURL)
    }

    func applyProfile(_ profile: ProviderProfile) throws {
        var document = (try loadDocument()) ?? TOMLFile()
        document.setValue(profile.profileKey, key: "model_provider", table: nil)
        if let model = profile.modelOverride, !model.isEmpty {
            document.setValue(model, key: "model", table: nil)
        }
        let table = ["model_providers", profile.profileKey]
        document.ensureTable(path: table)
        document.setValue(profile.name, key: "name", table: table)
        document.setValue(profile.baseURL, key: "base_url", table: table)
        document.setValue(Self.wireAPIForThirdParty, key: "wire_api", table: table)
        document.setValue(profile.token, key: "experimental_bearer_token", table: table)
        try write(document)
    }

    func clearOverrides() throws {
        guard let existing = try loadDocument() else { return } // 缺失 → 无事可做
        var document = existing
        let activeKey = document.stringValue(key: "model_provider", table: nil)
        document.remove(key: "model_provider", table: nil)
        document.remove(key: "model", table: nil)
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
