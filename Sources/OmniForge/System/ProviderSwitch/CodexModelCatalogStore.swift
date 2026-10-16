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
    /// - Parameters:
    ///   - priority: 目录内排序位（直连模式恒 1000；聚合模式末尾统一重排为 1...n）。
    ///   - compHash: 聚合来源标记（仅聚合目录的成员行注入 `"cc-switch"`；nil 不写键）。
    ///   - useResponsesLite: Responses Lite 形态开关（仅聚合目录成员行显式注入；nil 不写键）。
    static func catalogEntry(
        model: String,
        displayName: String,
        description: String,
        defaultReasoningLevel: String,
        priority: Int,
        compHash: String? = nil,
        useResponsesLite: Bool? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
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
            "priority": priority,
        ]
        if let compHash {
            entry["comp_hash"] = compHash
        }
        if let useResponsesLite {
            entry["use_responses_lite"] = useResponsesLite
        }
        return entry
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
                defaultReasoningLevel: defaultEffort,
                priority: 1000
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

    // MARK: - 聚合目录（多家供应商同列）

    /// 聚合目录字节（**不落盘**）— 写入与契约摘要（Task 18）共用同一生成路径，
    /// 摘要才能在「磁盘目录字节 vs 即将写入的目录字节」之间做无副作用比对。
    /// - `defaultKey`：默认那家在 `AggregationKeyRegistry` 里的 key（`toolStack.keyOf(profileID:)`），
    ///   用来认「哪些 `published` 行属于默认那家」。**不能**在库内用
    ///   `defaultProfile.profileKey` 推导——那是 `ProviderProfile.slugify`（拼音转换、不截断），
    ///   与登记簿的 ASCII-only + 24 位截断是两套刻意不同的规则（见 `AggregationKeyRegistry`），
    ///   名称含汉字时两者必然不同，一错位默认那家的模型就会在 `/model` 菜单里出现两遍。
    static func aggregatedCatalogData(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        defaultKey: String
    ) -> Data? {
        let root: [String: Any] = [
            "models": aggregatedCatalogEntries(defaultProfile: defaultProfile, published: published, defaultKey: defaultKey)
        ]
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// 生成并原子写入聚合目录。
    func writeAggregatedCatalog(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        defaultKey: String
    ) throws {
        guard let data = Self.aggregatedCatalogData(defaultProfile: defaultProfile, published: published, defaultKey: defaultKey) else {
            throw ProviderConfigFileError.writeFailed(path: catalogURL.path)
        }
        try AtomicFileWriter.write(data, to: catalogURL, fileManager: fileManager)
    }

    /// 聚合目录行组成：
    /// - **路由行在前**：默认那家的模型走普通 slug（不带前缀即可达默认供应商）。
    ///   来源优先取 `published` 中该 key 的条目（编排层传的是成员权威模型列表）；
    ///   默认那家未出现在 `published` 时回退 `defaultProfile.codexModelList`。
    /// - **成员行按 `published` 顺序追加**：Stack slug（`ccs-<key>/<model>`）、
    ///   全角展示名、`comp_hash = "cc-switch"`、`use_responses_lite = false`。
    /// - 全部行写入窗口下沉三键；结尾对整份列表重排 `priority = 1...n`。
    /// - `defaultKey`：默认那家的**登记簿** key（见 `aggregatedCatalogData` 的说明）。
    private static func aggregatedCatalogEntries(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        defaultKey: String
    ) -> [[String: Any]] {
        let defaultPublished = published.filter { $0.key == defaultKey }
        let defaultEffort = defaultProfile.reasoningEffort?.isEmpty == false ? defaultProfile.reasoningEffort! : "high"

        // (条目, 窗口) 成对构造，窗口在末尾统一下沉。
        var rows: [(entry: [String: Any], window: UInt64)] = []
        if !defaultPublished.isEmpty {
            for entry in defaultPublished {
                rows.append((
                    Self.catalogEntry(
                        model: entry.model,
                        displayName: "\(defaultProfile.name) (\(entry.model))",
                        description: "OmniForge 托管 · \(defaultProfile.name)",
                        defaultReasoningLevel: defaultEffort,
                        priority: 0
                    ),
                    entry.window
                ))
            }
        } else {
            // 回退：默认那家未在 published 中 —— 用其直连模型列表保证普通 slug 可达。
            let fallbackWindow = UInt64(defaultProfile.extraEnv["model_context_window"] ?? "") ?? 1_000_000
            for model in defaultProfile.codexModelList {
                rows.append((
                    Self.catalogEntry(
                        model: model,
                        displayName: "\(defaultProfile.name) (\(model))",
                        description: "OmniForge 托管 · \(defaultProfile.name)",
                        defaultReasoningLevel: defaultEffort,
                        priority: 0
                    ),
                    fallbackWindow
                ))
            }
        }
        for member in published where member.key != defaultKey {
            rows.append((
                Self.catalogEntry(
                    model: AggregationModelID.encode(
                        tool: .codex, key: member.key, model: member.model, oneM: member.oneM
                    ),
                    displayName: member.label,
                    description: member.description,
                    defaultReasoningLevel: defaultEffort,
                    priority: 0,
                    compHash: "cc-switch",
                    useResponsesLite: false
                ),
                member.window
            ))
        }
        return rows.enumerated().map { index, row in
            var entry = row.entry
            // 窗口下沉三键：目录行自治，不依赖 config.toml 顶层窗口键。
            entry["context_window"] = Int(row.window)
            entry["max_context_window"] = Int(row.window)
            entry["auto_compact_token_limit"] = Int(row.window * 9 / 10)
            entry["priority"] = index + 1
            return entry
        }
    }
}
