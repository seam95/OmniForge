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

    /// 中性身份提示词（对齐 cc-switch 的 native responses 模板）。
    ///
    /// **`base_instructions` 是 Codex 目录解析器的必需字段**：缺失时整份
    /// `config.toml` 加载失败（`failed to parse model_catalog_json ... as JSON:
    /// missing field base_instructions`），桌面端随即无法读取配置并报
    /// "Unable to load sign-in requirements"。故此处必须恒写入。
    static let neutralBaseInstructions = "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals."

    /// 单条模型目录条目。字段集对齐 Codex 的 catalog `Model` 结构（参照 cc-switch
    /// 的 native responses 模板）：除 `base_instructions` 外，其余字段均有默认值，
    /// 但显式声明可避免「中性模板塌缩」——原生 Responses 网关会拒绝 Codex 的
    /// freeform `apply_patch`（`type == "custom"`）工具，因此固定
    /// `shell_type = "shell_command"` 走 shell 改文件，并清空实验工具表。
    static func catalogEntry(
        model: String,
        displayName: String,
        description: String,
        defaultReasoningLevel: String
    ) -> [String: Any] {
        [
            "slug": model,
            "display_name": displayName,
            "description": description,
            "base_instructions": neutralBaseInstructions,
            "default_reasoning_level": defaultReasoningLevel,
            "supported_reasoning_levels": standardReasoningLevels,
            "shell_type": "shell_command",
            "experimental_supported_tools": [],
            "truncation_policy": ["mode": "bytes", "limit": 10_000],
            "supports_parallel_tool_calls": false,
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "none",
            "support_verbosity": false,
            "supports_search_tool": false,
            "supports_image_detail_original": false,
            "service_tiers": [],
            "additional_speed_tiers": [],
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
            "context_window": 1_000_000,
            "max_context_window": 1_000_000,
            "effective_context_window_percent": 95,
            "input_modalities": ["text"],
            "supported_in_api": true,
            "visibility": "list",
            "priority": 1000,
        ]
    }

    func writeCatalog(for profile: ProviderProfile) throws {
        let models = profile.codexModelList
        // 没有模型时不生成目录
        guard !models.isEmpty else {
            try? removeCatalog()
            return
        }

        let defaultEffort = profile.reasoningEffort?.isEmpty == false ? profile.reasoningEffort! : "high"
        let modelEntries: [[String: Any]] = models.map { model in
            Self.catalogEntry(
                model: model,
                displayName: "\(profile.name) (\(model))",
                description: "OmniForge 托管 · \(profile.name)",
                defaultReasoningLevel: defaultEffort
            )
        }

        let root: [String: Any] = [
            "models": modelEntries
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try AtomicFileWriter.write(data, to: catalogURL, fileManager: fileManager)
    }

    func removeCatalog() throws {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return }
        try fileManager.removeItem(at: catalogURL)
    }
}
