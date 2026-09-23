import Foundation

/// Codex 桌面端模型目录管理边界 — 生成并维护 `~/.codex/omniforge-model-catalog.json`。
protocol CodexModelCatalogStoring: AnyObject {
    var catalogURL: URL { get }
    /// 为指定 profile 投影生成并原子写入模型目录文件。
    func writeCatalog(for profile: ProviderProfile) throws
    /// 切回官方或无需自定义目录时清理该文件。
    func removeCatalog() throws
}

/// 负责将 OmniForge 配置的 Codex 第三方模型投影为符合 Codex Desktop 规格的模型目录。
final class CodexModelCatalogStore: CodexModelCatalogStoring {
    let catalogURL: URL
    let fileManager: FileManager

    init(
        catalogURL: URL = ProviderSwitchPaths.codexModelCatalogURL(),
        fileManager: FileManager = .default
    ) {
        self.catalogURL = catalogURL
        self.fileManager = fileManager
    }

    /// 规范化的完整思考等级列表（激活 Desktop 思考强度滑块与下拉选择）。
    static let standardReasoningLevels: [[String: String]] = [
        ["effort": "none", "description": "Disable Thinking"],
        ["effort": "minimal", "description": "Minimal Thinking"],
        ["effort": "low", "description": "Low Thinking"],
        ["effort": "medium", "description": "Medium Thinking"],
        ["effort": "high", "description": "High Thinking"],
        ["effort": "xhigh", "description": "Extra High Thinking"],
        ["effort": "max", "description": "Max Thinking"],
    ]

    func writeCatalog(for profile: ProviderProfile) throws {
        guard let model = profile.modelOverride, !model.isEmpty else {
            // 没有自定义模型覆盖时不生成目录
            try? removeCatalog()
            return
        }

        let defaultEffort = profile.reasoningEffort?.isEmpty == false ? profile.reasoningEffort! : "high"
        let modelEntry: [String: Any] = [
            "slug": model,
            "display_name": "\(profile.name) (\(model))",
            "description": "OmniForge 托管 · \(profile.name)",
            "default_reasoning_level": defaultEffort,
            "supported_reasoning_levels": Self.standardReasoningLevels,
            "context_window": 1_000_000,
            "max_context_window": 1_000_000,
            "effective_context_window_percent": 95,
            "input_modalities": ["text"],
            "supported_in_api": true,
            "visibility": "list",
            "priority": 1000,
        ]

        let root: [String: Any] = [
            "models": [modelEntry]
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: catalogURL, fileManager: fileManager)
    }

    func removeCatalog() throws {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return }
        try fileManager.removeItem(at: catalogURL)
    }
}
