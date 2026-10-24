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
    /// Codex 官方模型目录缓存路径（聚合官方行的唯一来源；默认 `~/.codex/models_cache.json`）。
    let modelsCacheURL: URL

    init(
        catalogURL: URL = ProviderSwitchPaths.codexModelCatalogURL(),
        modelsCacheURL: URL = ProviderSwitchPaths.codexModelsCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.catalogURL = catalogURL
        self.modelsCacheURL = modelsCacheURL
        self.fileManager = fileManager
    }

    /// 读取官方缓存目录（`models_cache.json`）的模型行：缺失/损坏/形状不符 → nil。
    /// 行内容原样返回（官方真实 base_instructions、窗口与能力字段都保留），仅
    /// `priority` 留给聚合合并重排。
    static func officialCacheRows(modelsCacheURL: URL, fileManager: FileManager = .default) -> [[String: Any]]? {
        guard fileManager.fileExists(atPath: modelsCacheURL.path),
              let data = try? Data(contentsOf: modelsCacheURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return nil
        }
        return models
    }

    /// 实例便捷读取：供编排层合成官方 profile 的模型列表。
    func officialCacheRows() -> [[String: Any]]? {
        Self.officialCacheRows(modelsCacheURL: modelsCacheURL, fileManager: fileManager)
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

    /// 聚合目录统一工作窗口（对齐 Codex 官方 GPT 的 272K 与 magpie 的默认）。
    ///
    /// 聚合里每个成员原本按自己的真实窗口告诉 Codex：1M 的 DeepSeek 与 272K 的 GPT
    /// 并存时，长会话从前者切到后者会被 Codex 判为“降窗”（`model_downshift`），
    /// 在发出下一条用户消息前先用旧模型压缩一次。统一成同一个工作窗口后，
    /// 供应商切换不再因窗口差异触发压缩；真实上限仍写 `max_context_window`。
    static let aggregationWorkingWindow: UInt64 = 272_000

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
    ///   - useResponsesLite: Responses Lite 形态开关（仅聚合目录成员行显式注入；nil 不写键）。
    ///   - inputModalities: 显式声明的输入模态（nil 时按模型名推导，见 `ModelImageCapability`）。
    ///   - reasoningLevels: 条目级思考档位覆盖（nil = 默认七档全列）。
    ///   - reasoningDefault: 条目级默认档位（仅与 `reasoningLevels` 同用有效；裁决见
    ///     `resolvedReasoningDefault`）。
    ///   - baseInstructions: 条目级身份提示词覆盖（nil = 中性默认）。当前无数据来源，
    ///     为将来接入预设元数据 / models.dev 预留，写入器零改动。
    ///   - supportsParallelToolCalls: 条目级并行工具调用覆盖（nil = 保守 false）。预留同上。
    static func catalogEntry(
        model: String,
        displayName: String,
        description: String,
        defaultReasoningLevel: String,
        priority: Int,
        contextWindow: UInt64? = nil,
        useResponsesLite: Bool? = nil,
        inputModalities: [String]? = nil,
        reasoningLevels: [String]? = nil,
        reasoningDefault: String? = nil,
        baseInstructions: String? = nil,
        supportsParallelToolCalls: Bool? = nil
    ) -> [String: Any] {
        let window = Int(contextWindow ?? 1_000_000)
        // 档位覆盖（对齐 cc-switch `apply_codex_reasoning_level_override`）：
        // 配了列表 → 覆盖 supported_reasoning_levels（字符串数组，对齐 cc-switch 覆盖形状），
        // default 按「显式命中 → 模板默认命中 → 列表最高档」裁决；
        // 未配列表 → 保持七档对象数组（带描述，激活 Desktop 强度滑块），default 保持模板值。
        let supportedLevels: [Any]
        if let reasoningLevels {
            supportedLevels = reasoningLevels
        } else {
            supportedLevels = standardReasoningLevels
        }
        let effectiveDefault = resolvedReasoningDefault(
            levels: reasoningLevels, explicitDefault: reasoningDefault, fallback: defaultReasoningLevel
        )
        var entry: [String: Any] = [
            "slug": model,
            "display_name": displayName,
            "description": description,
            "base_instructions": baseInstructions ?? neutralBaseInstructions,
            "default_reasoning_level": effectiveDefault,
            "supported_reasoning_levels": supportedLevels,
            "shell_type": "shell_command",
            "experimental_supported_tools": [],
            "truncation_policy": ["mode": "bytes", "limit": 10_000],
            "supports_parallel_tool_calls": supportsParallelToolCalls ?? false,
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "none",
            "support_verbosity": false,
            "supports_search_tool": false,
            "supports_image_detail_original": false,
            "service_tiers": [],
            "additional_speed_tiers": [],
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
            "context_window": window,
            "max_context_window": window,
            "effective_context_window_percent": 95,
            // 能力判定 fail-open：确认纯文本名单之外一律声明 text+image。
            // Codex 只按该字段决定是否允许发图；写死 ["text"] 会把多模态模型提前拦死。
            "input_modalities": inputModalities ?? ModelImageCapability.inputModalities(for: model),
            "supported_in_api": true,
            "visibility": "list",
            "priority": priority,
        ]
        if let useResponsesLite {
            entry["use_responses_lite"] = useResponsesLite
        }
        return entry
    }

    /// 条目级默认档位裁决（仅当 `levels` 非空时生效）：
    /// 1. 显式默认档在列表内 → 用之；
    /// 2. 未配 / 不在列表 → 模板默认（profile effort ?? high）在列表内 → 用之；
    /// 3. 都不在 → 列表最高档（`CodexReasoningLevel.ordered` 序的最后一项）。
    static func resolvedReasoningDefault(
        levels: [String]?,
        explicitDefault: String?,
        fallback: String
    ) -> String {
        guard let levels, !levels.isEmpty else { return fallback }
        if let explicitDefault, levels.contains(explicitDefault) {
            return explicitDefault
        }
        if levels.contains(fallback) {
            return fallback
        }
        return CodexReasoningLevel.ordered.last { levels.contains($0) } ?? fallback
    }

    func writeCatalog(for profile: ProviderProfile) throws {
        let entries = profile.codexModelEntries
        // 没有模型时不生成目录
        guard !entries.isEmpty else {
            try? removeCatalog()
            return
        }

        let defaultEffort = profile.reasoningEffort?.isEmpty == false ? profile.reasoningEffort! : "high"
        // 未按模型配置窗口时回落到供应商级 `model_context_window`；再缺省才用 1M。
        // 逐模型窗口必须写进目录：Codex 只按目录行决定发送与压缩，表单里的值不写就无效。
        let fallbackWindow = UInt64(profile.extraEnv["model_context_window"] ?? "") ?? 1_000_000
        let modelEntries: [[String: Any]] = entries.map { entry in
            Self.catalogEntry(
                model: entry.model,
                displayName: entry.displayName ?? "\(profile.name) (\(entry.model))",
                description: "OmniForge 托管 · \(profile.name)",
                defaultReasoningLevel: defaultEffort,
                priority: 1000,
                contextWindow: entry.contextWindow ?? fallbackWindow,
                reasoningLevels: entry.reasoningLevels,
                reasoningDefault: entry.defaultReasoningLevel
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
    /// - `officialCacheRows`：默认那家是官方时的官方行来源（`models_cache.json` 原样行），
    ///   由调用方（`AggregationCodexConfigWriter`）统一解析显式传入——写盘与契约摘要
    ///   两条路径必须同源，否则「未变更不重写」闸门会误判。nil = 非官方默认或缓存缺失。
    static func aggregatedCatalogData(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        defaultKey: String,
        officialCacheRows: [[String: Any]]? = nil
    ) -> Data? {
        let root: [String: Any] = [
            "models": aggregatedCatalogEntries(
                defaultProfile: defaultProfile, published: published, defaultKey: defaultKey,
                officialCacheRows: officialCacheRows
            )
        ]
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// 生成并原子写入聚合目录。
    func writeAggregatedCatalog(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        defaultKey: String,
        officialCacheRows: [[String: Any]]? = nil
    ) throws {
        guard let data = Self.aggregatedCatalogData(
            defaultProfile: defaultProfile, published: published, defaultKey: defaultKey,
            officialCacheRows: officialCacheRows
        ) else {
            throw ProviderConfigFileError.writeFailed(path: catalogURL.path)
        }
        try AtomicFileWriter.write(data, to: catalogURL, fileManager: fileManager)
    }

    /// 聚合目录行组成：
    /// - **官方默认**（`defaultProfile.isOfficial`）：默认行改用 `models_cache.json` 的
    ///   **原样行**（官方真实 base_instructions、窗口、能力字段都保留，不套中性模板——
    ///   模板的保守值会降级官方体验）。顺序按 `published` 的官方行 slug 对齐；缓存缺失
    ///   时安全降级为空（官方行不进目录，Codex 回落内置默认模型）。
    /// - **路由行在前**：默认那家的模型走普通 slug（不带前缀即可达默认供应商）。
    ///   来源优先取 `published` 中该 key 的条目（编排层传的是成员权威模型列表）；
    ///   默认那家未出现在 `published` 时回退 `defaultProfile.codexModelList`。
    ///   聚合成员行**不写** `comp_hash`：Codex 只在切换前后两行都声明该值且不同时，
    ///   才先用**上一个模型**做 inline compact（`comp_hash_changed` 要求两侧都有值）。
    ///   缺省后，第三方与第三方、第三方与官方之间切换都不会触发这次压缩；上一家额度
    ///   用完时压缩失败、自定义供应商不会改用当前模型重试的问题（cc-switch #8485）
    ///   因此一并规避。官方路由行保留原生行（含原生 `comp_hash`）——官方失败时 Codex
    ///   会改用当前模型重试，官方压缩语义也保持不变。
    /// - **成员行按 `published` 顺序追加**：Stack slug（`om-<key>/<model>`）、
    ///   全角展示名、`use_responses_lite = false`。
    /// - 全部行写入统一工作窗口：`context_window = min(真实窗口, 272K)`、
    ///   `max_context_window = 真实窗口`，并删除 `auto_compact_token_limit`；
    ///   结尾对整份列表重排 `priority = 1...n`。
    /// - `defaultKey`：默认那家的**登记簿** key（见 `aggregatedCatalogData` 的说明）。
    private static func aggregatedCatalogEntries(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        defaultKey: String,
        officialCacheRows: [[String: Any]]? = nil
    ) -> [[String: Any]] {
        if defaultProfile.isOfficial {
            return officialEntries(
                published: published, defaultKey: defaultKey, officialCacheRows: officialCacheRows ?? []
            )
        }

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
                    useResponsesLite: false,
                    // 成员行 slug 带 `om-<key>/` 前缀，按真实模型名推导能力，不依赖 slug 形态。
                    inputModalities: ModelImageCapability.inputModalities(for: member.model)
                ),
                member.window
            ))
        }
        return rows.enumerated().map { index, row in
            var entry = row.entry
            // 统一工作窗口：目录行自治，不依赖 config.toml 顶层窗口键。
            Self.sinkWorkingWindow(&entry, contextWindow: row.window)
            entry["priority"] = index + 1
            return entry
        }
    }

    /// 把真实窗口下沉为“工作窗口 + 真实上限”：
    /// - `context_window = min(真实窗口, 272K)`：Codex 按它计算自动压缩点（90%），
    ///   不同供应商的切换不再被判定为 `model_downshift`；
    /// - `max_context_window = 真实窗口`：保留模型实际上限，供 Codex 展示与校验；
    /// - 删除 `auto_compact_token_limit`：Codex 默认取 `context_window` 的 90%，
    ///   且该键会被 `min(值, 90%)` 封顶，原写法与默认值相同、没有配置作用。
    private static func sinkWorkingWindow(
        _ entry: inout [String: Any],
        contextWindow: UInt64,
        maxWindow: UInt64? = nil
    ) {
        guard contextWindow > 0 else { return }
        entry["context_window"] = Int(min(contextWindow, aggregationWorkingWindow))
        entry["max_context_window"] = Int(max(maxWindow ?? contextWindow, contextWindow))
        entry.removeValue(forKey: "auto_compact_token_limit")
    }

    /// 官方默认的目录行：官方缓存原样行在前（顺序对齐 `published` 的官方 slug——
    /// 即合成官方卡 `codexModels` 的顺序），成员行照常追加，`priority` 统一重排。
    /// 官方行**只改窗口三键**（其余原生字段与 `comp_hash` 保持缓存原值）：统一工作窗口
    /// 后，从第三方 1M 模型切到官方 500K 模型也不再被判定为降窗。
    private static func officialEntries(
        published: [AggregationPublishedModel],
        defaultKey: String,
        officialCacheRows: [[String: Any]]
    ) -> [[String: Any]] {
        let cacheBySlug = Dictionary(
            officialCacheRows.compactMap { row -> (String, [String: Any])? in
                guard let slug = row["slug"] as? String else { return nil }
                return (slug, row)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var rows: [[String: Any]] = []
        var seenSlugs = Set<String>()
        // 官方默认行：published 的官方行顺序为准（缓存里没有的 slug 跳过——缓存是
        // 唯一权威来源，不凭空造行）。
        for entry in published where entry.key == defaultKey {
            guard let cached = cacheBySlug[entry.model], seenSlugs.insert(entry.model).inserted else { continue }
            var row = cached
            // 原生窗口：context 为工作窗口，max 为真实上限；缺 context 时用 max 兜底。
            let context = (row["context_window"] as? Int) ?? (row["max_context_window"] as? Int) ?? 0
            let maxWindow = row["max_context_window"] as? Int
            Self.sinkWorkingWindow(
                &row,
                contextWindow: UInt64(max(context, 0)),
                maxWindow: maxWindow.map { UInt64(max($0, 0)) }
            )
            rows.append(row)
        }
        // 主动拉取到的新模型可能还没进合成官方卡（profile 的 codexModels 来自 models_cache）：
        // 缓存里多出来的行也要追加，否则新模型会被静默丢掉。
        for cached in officialCacheRows {
            guard let slug = cached["slug"] as? String, seenSlugs.insert(slug).inserted else { continue }
            var row = cached
            let context = (row["context_window"] as? Int) ?? (row["max_context_window"] as? Int) ?? 0
            let maxWindow = row["max_context_window"] as? Int
            Self.sinkWorkingWindow(
                &row,
                contextWindow: UInt64(max(context, 0)),
                maxWindow: maxWindow.map { UInt64(max($0, 0)) }
            )
            rows.append(row)
        }
        // 成员行：与非官方路径同构（Stack slug + 窗口下沉，不写 comp_hash）。
        let memberRows: [(entry: [String: Any], window: UInt64)] =
            published.filter { $0.key != defaultKey }.map { member in
                (
                    Self.catalogEntry(
                        model: AggregationModelID.encode(
                            tool: .codex, key: member.key, model: member.model, oneM: member.oneM
                        ),
                        displayName: member.label,
                        description: member.description,
                        defaultReasoningLevel: "high",
                        priority: 0,
                        useResponsesLite: false,
                        // 成员行 slug 带 `om-<key>/` 前缀，按真实模型名推导能力。
                        inputModalities: ModelImageCapability.inputModalities(for: member.model)
                    ),
                    member.window
                )
            }
        for row in memberRows {
            var entry = row.entry
            Self.sinkWorkingWindow(&entry, contextWindow: row.window)
            rows.append(entry)
        }
        // priority 重排：官方行保持缓存原值不覆盖（Codex 对官方行的 priority 语义
        // 已在其缓存里排好），成员行顺延官方行数之后。
        let officialCount = rows.count - memberRows.count
        for index in rows.indices.dropFirst(officialCount) {
            rows[index]["priority"] = officialCount + (index - officialCount) + 1
        }
        return rows
    }
}
