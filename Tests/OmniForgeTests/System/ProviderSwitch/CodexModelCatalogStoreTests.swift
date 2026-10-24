import XCTest
@testable import OmniForge

final class CodexModelCatalogStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var catalogURL: URL!
    private var store: CodexModelCatalogStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexModelCatalogStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        catalogURL = tmpDir.appendingPathComponent("omniforge-model-catalog.json")
        store = CodexModelCatalogStore(catalogURL: catalogURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeProfile(
        name: String = "DeepSeek",
        key: String = "deepseek",
        model: String? = "deepseek-reasoner",
        reasoningEffort: String? = "high"
    ) -> ProviderProfile {
        ProviderProfile(
            id: key,
            name: name,
            tool: .codex,
            baseURL: "https://api.deepseek.com/v1",
            token: "sk-test",
            modelOverride: model,
            reasoningEffort: reasoningEffort,
            modelMapping: nil,
            extraEnv: [:],
            managedBy: ProviderProfile.managedByMarker
        )
    }

    private func makePublished(
        key: String,
        profileName: String,
        model: String,
        upstream: String? = nil,
        displayName: String? = nil,
        window: UInt64 = 256_000,
        oneM: Bool = false
    ) -> AggregationPublishedModel {
        AggregationPublishedModel(
            key: key,
            profileName: profileName,
            model: model,
            upstream: upstream ?? model,
            displayName: displayName ?? model,
            oneM: oneM,
            window: window
        )
    }

    private func readModels() throws -> [[String: Any]] {
        let data = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["models"] as? [[String: Any]])
    }

    func test_writeCatalog_withCustomModel_generatesValidJSON() throws {
        let profile = makeProfile(name: "GLM", model: "glm-4-7", reasoningEffort: "medium")
        try store.writeCatalog(for: profile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        let data = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 1)

        let first = try XCTUnwrap(models.first)
        XCTAssertEqual(first["slug"] as? String, "glm-4-7")
        XCTAssertEqual(first["display_name"] as? String, "GLM (glm-4-7)")
        XCTAssertEqual(first["description"] as? String, "OmniForge 托管 · GLM")
        XCTAssertEqual(first["default_reasoning_level"] as? String, "medium")
        XCTAssertEqual(first["context_window"] as? Int, 1_000_000)
        XCTAssertEqual(first["max_context_window"] as? Int, 1_000_000)
        XCTAssertEqual(first["effective_context_window_percent"] as? Int, 95)
        XCTAssertEqual(first["supported_in_api"] as? Bool, true)
        XCTAssertEqual(first["visibility"] as? String, "list")
        XCTAssertEqual(first["priority"] as? Int, 1000)

        let levels = try XCTUnwrap(first["supported_reasoning_levels"] as? [[String: String]])
        let effortValues = levels.compactMap { $0["effort"] }
        XCTAssertEqual(effortValues, ["none", "minimal", "low", "medium", "high", "xhigh", "max"])
    }

    /// 回归：Codex 的目录解析器把 `base_instructions` 当必需字段，缺失时整份
    /// `config.toml` 加载失败（桌面端报 "Unable to load sign-in requirements"）。
    /// 生成器必须恒写入该字段，且工具形态固定为 shell_command + 空实验工具表
    /// （原生 Responses 网关拒绝 Codex 的 freeform apply_patch）。
    func test_writeCatalog_includesCodexRequiredFields() throws {
        let profile = makeProfile(name: "GLM", model: "glm-4-7", reasoningEffort: "medium")
        try store.writeCatalog(for: profile)

        let data = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap(try XCTUnwrap(json["models"] as? [[String: Any]]).first)

        XCTAssertFalse((first["base_instructions"] as? String ?? "").isEmpty, "base_instructions 为必需字段，缺失会导致 config.toml 加载失败")
        XCTAssertEqual(first["shell_type"] as? String, "shell_command")
        XCTAssertTrue((first["experimental_supported_tools"] as? [Any])?.isEmpty == true, "实验工具表须为空数组")
        XCTAssertEqual(first["supports_parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(first["supports_reasoning_summaries"] as? Bool, true)
        XCTAssertEqual(first["default_reasoning_summary"] as? String, "none")
        XCTAssertEqual(first["support_verbosity"] as? Bool, false)
        XCTAssertEqual(first["supports_search_tool"] as? Bool, false)
        XCTAssertEqual(first["supports_image_detail_original"] as? Bool, false)
        XCTAssertTrue((first["service_tiers"] as? [Any])?.isEmpty == true, "service_tiers 须为空数组")
        XCTAssertTrue((first["additional_speed_tiers"] as? [Any])?.isEmpty == true, "additional_speed_tiers 须为空数组")
        XCTAssertEqual(first["availability_nux"] as? NSNull, NSNull())
        XCTAssertEqual(first["upgrade"] as? NSNull, NSNull())

        let truncation = try XCTUnwrap(first["truncation_policy"] as? [String: Any])
        XCTAssertEqual(truncation["mode"] as? String, "bytes")
        XCTAssertEqual(truncation["limit"] as? Int, 10_000)
    }

    func test_writeCatalog_defaultEffortFallbackWhenNil() throws {
        let profile = makeProfile(name: "GLM", model: "glm-4-7", reasoningEffort: nil)
        try store.writeCatalog(for: profile)

        let data = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        let first = try XCTUnwrap(models.first)
        XCTAssertEqual(first["default_reasoning_level"] as? String, "high")
    }

    func test_writeCatalog_withoutModelOverride_removesExistingCatalog() throws {
        try Data("{}".utf8).write(to: catalogURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        let profile = makeProfile(model: nil)
        try store.writeCatalog(for: profile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    func test_writeCatalog_multipleModels_writesAllEntriesInOrder() throws {
        let profile = ProviderProfile(
            id: "glm",
            name: "GLM",
            tool: .codex,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            token: "sk-test",
            reasoningEffort: "medium",
            codexModels: ["glm-5.3", "glm-4.7-air"],
            managedBy: ProviderProfile.managedByMarker
        )
        try store.writeCatalog(for: profile)

        let data = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)

        XCTAssertEqual(models[0]["slug"] as? String, "glm-5.3")
        XCTAssertEqual(models[0]["display_name"] as? String, "GLM (glm-5.3)")
        XCTAssertEqual(models[0]["default_reasoning_level"] as? String, "medium")
        XCTAssertEqual(models[0]["priority"] as? Int, 1000)
        XCTAssertEqual(models[1]["slug"] as? String, "glm-4.7-air")
        XCTAssertEqual(models[1]["display_name"] as? String, "GLM (glm-4.7-air)")
        XCTAssertEqual(models[1]["default_reasoning_level"] as? String, "medium")
    }

    func test_writeCatalog_emptyCodexModelsArray_removesExistingCatalog() throws {
        try Data("{}".utf8).write(to: catalogURL)
        let profile = ProviderProfile(
            id: "glm",
            name: "GLM",
            tool: .codex,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            token: "sk-test",
            codexModels: [],
            managedBy: ProviderProfile.managedByMarker
        )
        try store.writeCatalog(for: profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path), "删空列表即清理目录")
    }

    // MARK: - 思考档位覆盖（对齐 cc-switch apply_codex_reasoning_level_override）

    func test_resolvedReasoningDefault_threeBranches() {
        // 显式默认在列表内 → 用之
        XCTAssertEqual(
            CodexModelCatalogStore.resolvedReasoningDefault(levels: ["low", "high"], explicitDefault: "low", fallback: "high"),
            "low"
        )
        // 未配默认、模板默认在列表 → 模板默认
        XCTAssertEqual(
            CodexModelCatalogStore.resolvedReasoningDefault(levels: ["low", "high"], explicitDefault: nil, fallback: "high"),
            "high"
        )
        // 显式默认不在列表且模板默认不在列表 → 列表最高档
        XCTAssertEqual(
            CodexModelCatalogStore.resolvedReasoningDefault(levels: ["none", "low"], explicitDefault: "max", fallback: "high"),
            "low"
        )
        // 未配列表 → 模板值原样（条目级 default 单独无效）
        XCTAssertEqual(
            CodexModelCatalogStore.resolvedReasoningDefault(levels: nil, explicitDefault: "low", fallback: "medium"),
            "medium"
        )
    }

    func test_writeCatalog_reasoningLevelsOverrideFromProfile() throws {
        let profile = ProviderProfile(
            id: "glm",
            name: "GLM",
            tool: .codex,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            token: "sk-test",
            codexModels: ["glm-5.3", "glm-4.7-air"],
            modelReasoningLevels: ["none,low,high", ""],
            modelDefaultReasoningLevels: ["low", ""]
        )
        try store.writeCatalog(for: profile)

        let data = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])

        // 覆盖行：字符串数组形状 + 显式默认档
        let overridden = try XCTUnwrap(models.first { $0["slug"] as? String == "glm-5.3" })
        XCTAssertEqual(overridden["supported_reasoning_levels"] as? [String], ["none", "low", "high"])
        XCTAssertEqual(overridden["default_reasoning_level"] as? String, "low")

        // 未覆盖行：保持七档对象数组（带描述）+ 模板默认档
        let untouched = try XCTUnwrap(models.first { $0["slug"] as? String == "glm-4.7-air" })
        let standardLevels = untouched["supported_reasoning_levels"] as? [[String: Any]]
        XCTAssertEqual(standardLevels?.count, 7, "未配置档位覆盖时保持默认七档对象形状")
        XCTAssertEqual(untouched["default_reasoning_level"] as? String, "high")
    }

    func test_removeCatalog_deletesFileIfExists() throws {
        try Data("{}".utf8).write(to: catalogURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        try store.removeCatalog()
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))

        // 文件不存在时再次调用不报错
        XCTAssertNoThrow(try store.removeCatalog())
    }

    // MARK: - 聚合目录（多家供应商同列）

    func test_writeAggregatedCatalog_routeRowsFirstThenMembersInJoinOrder() throws {
        let ds = makeProfile(name: "DeepSeek", key: "deepseek")
        let published = [
            makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3"),
            makePublished(key: "deepseek", profileName: "DeepSeek", model: "deepseek-v4-pro")
        ]
        try store.writeAggregatedCatalog(defaultProfile: ds, published: published, defaultKey: "deepseek")

        let models = try readModels()
        XCTAssertEqual(models.map { $0["slug"] as? String }, ["deepseek-v4-pro", "om-kimi/kimi-k3"])
        XCTAssertEqual(models.map { $0["priority"] as? Int }, [1, 2])
    }

    func test_writeAggregatedCatalog_memberRowGetsStackSlugAndNoCompHash() throws {
        let published = [makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3")]
        try store.writeAggregatedCatalog(defaultProfile: makeProfile(name: "DeepSeek", key: "deepseek"),
                                         published: published, defaultKey: "deepseek")
        let row = try XCTUnwrap(try readModels().first { ($0["slug"] as? String) == "om-kimi/kimi-k3" })
        XCTAssertNil(row["comp_hash"], "第三方行不写 comp_hash：跨来源切换不再触发预压缩")
        XCTAssertEqual(row["display_name"] as? String, "kimi-k3（Kimi）")
        XCTAssertEqual(row["description"] as? String, "kimi-k3 · 256K")
    }

    /// 回归（cc-switch #8485）：第三方路由行同样不写 `comp_hash`。
    /// Codex 的 `comp_hash_changed` 要求两侧都有值，缺省后与成员行、官方行之间
    /// 切换都不会先用上一家模型压缩（上一家额度用完会卡死会话）。
    func test_writeAggregatedCatalog_routeRowOmitsCompHash() throws {
        try store.writeAggregatedCatalog(defaultProfile: makeProfile(name: "DeepSeek", key: "deepseek"),
                                         published: [], defaultKey: "deepseek")
        let row = try XCTUnwrap(try readModels().first { ($0["slug"] as? String) == "deepseek-reasoner" })
        XCTAssertNil(row["comp_hash"])
    }

    /// 回归：所有聚合行共用 272K 工作窗口，真实上限仍写 `max_context_window`；
    /// `auto_compact_token_limit` 不再写入（Codex 默认取工作窗口的 90%）。
    func test_writeAggregatedCatalog_sinksUnifiedWorkingWindow() throws {
        let published = [
            makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3", window: 400_000),
            makePublished(key: "ds", profileName: "DeepSeek", model: "deepseek-v4", window: 1_000_000),
            makePublished(key: "small", profileName: "Small", model: "small-128k", window: 128_000)
        ]
        try store.writeAggregatedCatalog(defaultProfile: makeProfile(name: "DeepSeek", key: "deepseek"),
                                         published: published, defaultKey: "deepseek")

        let models = try readModels()
        let kimi = try XCTUnwrap(models.first { ($0["slug"] as? String) == "om-kimi/kimi-k3" })
        XCTAssertEqual(kimi["context_window"] as? Int, 272_000)
        XCTAssertEqual(kimi["max_context_window"] as? Int, 400_000)
        XCTAssertNil(kimi["auto_compact_token_limit"])

        let deepseek = try XCTUnwrap(models.first { ($0["slug"] as? String) == "om-ds/deepseek-v4" })
        XCTAssertEqual(deepseek["context_window"] as? Int, 272_000, "1M 模型也按统一工作窗口压缩")
        XCTAssertEqual(deepseek["max_context_window"] as? Int, 1_000_000)

        let small = try XCTUnwrap(models.first { ($0["slug"] as? String) == "om-small/small-128k" })
        XCTAssertEqual(small["context_window"] as? Int, 128_000, "小于工作窗口时保留真实窗口")
        XCTAssertEqual(small["max_context_window"] as? Int, 128_000)
    }

    func test_writeAggregatedCatalog_forcesUseResponsesLiteFalseOnlyWhenOriginallyTrue() throws {
        let published = [makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3")]
        try store.writeAggregatedCatalog(defaultProfile: makeProfile(name: "DeepSeek", key: "deepseek"),
                                         published: published, defaultKey: "deepseek")
        let row = try XCTUnwrap(try readModels().first { ($0["slug"] as? String) == "om-kimi/kimi-k3" })
        XCTAssertNotEqual(row["use_responses_lite"] as? Bool, true)
    }

    /// 回归：默认那家的目录行归属必须按**登记簿 key**（`AggregationKeyRegistry.slug`：
    /// ASCII-only、截断 24）判定，不能用 `ProviderProfile.profileKey`（`slugify`：拼音转换、
    /// 不截断）——两套规则刻意不同，名称含汉字时必然不一致（`"GLM 智谱"` → profileKey
    /// `glm-zhi-pu` vs 登记簿 key `glm`）。一旦用错，`defaultPublished` 为空 →
    /// 回退分支发一遍普通 slug 行、成员循环再把同一批模型发成 `om-glm/<model>` 行，
    /// `/model` 菜单里每个默认模型出现两遍，且普通行走的是旧的展示名与 extraEnv 窗口回落。
    func test_writeAggregatedCatalog_defaultModelsAppearExactlyOnceForNonASCIIProfileName() throws {
        let glm = makeProfile(name: "GLM 智谱", key: "glm")
        XCTAssertEqual(glm.profileKey, "glm-zhi-pu", "拼音 slug 与登记簿 key 分属两套规则")
        let published = [
            makePublished(key: "glm", profileName: "GLM 智谱", model: "glm-5.3", window: 200_000),
            makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3")
        ]

        try store.writeAggregatedCatalog(defaultProfile: glm, published: published, defaultKey: "glm")

        let models = try readModels()
        XCTAssertEqual(models.map { $0["slug"] as? String }, ["glm-5.3", "om-kimi/kimi-k3"])
        XCTAssertEqual(
            models.filter { ($0["slug"] as? String)?.contains("glm-5.3") == true }.count, 1,
            "默认那家的模型只出现一次（普通 slug 路由行），不得再出一条 om- 成员行"
        )
        let routeRow = try XCTUnwrap(models.first)
        XCTAssertNil(routeRow["comp_hash"], "聚合成员行不写 comp_hash")
        XCTAssertEqual(routeRow["display_name"] as? String, "GLM 智谱 (glm-5.3)")
        XCTAssertEqual(routeRow["context_window"] as? Int, 200_000, "窗口取发布条目值，不是 extraEnv 全局回落")
    }

    /// 主动拉取列表里的新模型可能还没进合成官方卡；目录必须把它补进来。
    func test_writeAggregatedCatalog_includesFetchedOfficialModelsBeyondPublishedList() throws {
        let official = ProviderProfile(
            id: "openai", name: "OpenAI", tool: .codex,
            baseURL: "https://api.openai.com/v1", token: "",
            codexModels: ["gpt-known"]
        )
        let published = [
            makePublished(key: "openai", profileName: "OpenAI", model: "gpt-known", window: 272_000),
        ]
        let cache: [[String: Any]] = [
            ["slug": "gpt-known", "comp_hash": "3000", "context_window": 272_000, "visibility": "list"],
            ["slug": "gpt-fetched-new", "comp_hash": "3000", "context_window": 500_000, "visibility": "list"],
        ]
        try store.writeAggregatedCatalog(
            defaultProfile: official, published: published, defaultKey: "openai",
            officialCacheRows: cache
        )
        let models = try readModels()
        XCTAssertEqual(models.map { $0["slug"] as? String }, ["gpt-known", "gpt-fetched-new"])
        XCTAssertEqual(models[1]["context_window"] as? Int, 272_000, "新模型同样下沉工作窗口")
        XCTAssertEqual(models[1]["max_context_window"] as? Int, 500_000)
    }

    /// 官方行保留原生 `comp_hash`（Codex 官方压缩语义与失败重试），但窗口同样下沉到
    /// 统一工作窗口，避免从第三方 1M 成员切到官方 500K 模型时被判为降窗。
    func test_writeAggregatedCatalog_officialRowsKeepCompHashButShareWorkingWindow() throws {
        let official = ProviderProfile(
            id: "openai",
            name: "OpenAI",
            tool: .codex,
            baseURL: "https://api.openai.com/v1",
            token: "",
            codexModels: ["gpt-5.6-sol", "gpt-6.1-sol"]
        )
        let published = [
            makePublished(key: "openai", profileName: "OpenAI", model: "gpt-5.6-sol", window: 272_000),
            makePublished(key: "openai", profileName: "OpenAI", model: "gpt-6.1-sol", window: 500_000),
            makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3", window: 1_000_000)
        ]
        let cache: [[String: Any]] = [
            [
                "slug": "gpt-5.6-sol", "comp_hash": "3000",
                "context_window": 272_000, "max_context_window": 872_000,
                "auto_compact_token_limit": 244_800, "base_instructions": "OFFICIAL",
            ],
            [
                "slug": "gpt-6.1-sol", "comp_hash": "3000",
                "context_window": 500_000, "max_context_window": 872_000,
                "base_instructions": "OFFICIAL",
            ],
        ]
        try store.writeAggregatedCatalog(
            defaultProfile: official, published: published, defaultKey: "openai",
            officialCacheRows: cache
        )

        let models = try readModels()
        let sol = try XCTUnwrap(models.first { ($0["slug"] as? String) == "gpt-5.6-sol" })
        XCTAssertEqual(sol["comp_hash"] as? String, "3000", "官方行保留原生压缩标识")
        XCTAssertEqual(sol["base_instructions"] as? String, "OFFICIAL", "官方行不套中性模板")
        XCTAssertEqual(sol["context_window"] as? Int, 272_000)
        XCTAssertEqual(sol["max_context_window"] as? Int, 872_000)
        XCTAssertNil(sol["auto_compact_token_limit"])

        let sol61 = try XCTUnwrap(models.first { ($0["slug"] as? String) == "gpt-6.1-sol" })
        XCTAssertEqual(sol61["context_window"] as? Int, 272_000, "官方 500K 行也按统一工作窗口")
        XCTAssertEqual(sol61["max_context_window"] as? Int, 872_000)

        let kimi = try XCTUnwrap(models.first { ($0["slug"] as? String) == "om-kimi/kimi-k3" })
        XCTAssertNil(kimi["comp_hash"])
        XCTAssertEqual(kimi["context_window"] as? Int, 272_000)
        XCTAssertEqual(kimi["max_context_window"] as? Int, 1_000_000)
    }

    // MARK: - 图像输入能力（对齐 cc-switch v4.0.16 的 fail-open 口径）

    /// 未确认模型（含新别名/视觉变体）声明 `["text","image"]`，
    /// 否则 Codex 会在添加图片时直接拦截聚合模式下的多模态模型。
    /// 回归：直连目录必须使用表单里的逐模型窗口。此前统一写 1M，
    /// 128K/256K 模型会被 Codex 按 1M 发送，直到上游拒绝。
    func test_writeCatalog_usesPerModelContextWindows() throws {
        let profile = ProviderProfile(
            id: "relay",
            name: "Relay",
            tool: .codex,
            baseURL: "https://relay.example.com/v1",
            token: "sk-test",
            reasoningEffort: "high",
            codexModels: ["small-128k", "big-1m"],
            modelDisplayNames: ["Small", ""],
            modelContextWindows: ["128000", "1000000"],
            managedBy: ProviderProfile.managedByMarker
        )
        try store.writeCatalog(for: profile)

        let models = try readModels()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["context_window"] as? Int, 128_000)
        XCTAssertEqual(models[0]["max_context_window"] as? Int, 128_000)
        XCTAssertEqual(models[0]["display_name"] as? String, "Small", "逐模型显示名生效")
        XCTAssertEqual(models[1]["context_window"] as? Int, 1_000_000)
    }

    func test_writeCatalog_fallsBackToProviderWindowWhenModelWindowMissing() throws {
        let profile = ProviderProfile(
            id: "relay",
            name: "Relay",
            tool: .codex,
            baseURL: "https://relay.example.com/v1",
            token: "sk-test",
            codexModels: ["m"],
            extraEnv: ["model_context_window": "256000"],
            managedBy: ProviderProfile.managedByMarker
        )
        try store.writeCatalog(for: profile)
        let row = try XCTUnwrap(try readModels().first)
        XCTAssertEqual(row["context_window"] as? Int, 256_000)
        XCTAssertEqual(row["max_context_window"] as? Int, 256_000)
    }

    func test_writeCatalog_infersInputModalitiesFailOpen() throws {
        let profile = makeProfile(name: "OpenCode", key: "opencode-go", model: "deepseek-v4.1-flash")
        try store.writeCatalog(for: profile)
        let row = try XCTUnwrap(readModels().first)
        XCTAssertEqual(row["input_modalities"] as? [String], ["text", "image"])
    }

    func test_writeCatalog_confirmedTextOnlyModelStaysText() throws {
        let profile = makeProfile(name: "DeepSeek", key: "deepseek", model: "deepseek-chat")
        try store.writeCatalog(for: profile)
        let row = try XCTUnwrap(readModels().first)
        XCTAssertEqual(row["input_modalities"] as? [String], ["text"])
    }

    /// 成员行 slug 带 `om-<key>/` 前缀，能力必须按真实模型名推导：
    /// glm-5.3 在确认纯文本名单 → text；kimi-k3 未确认 → text+image。
    func test_writeAggregatedCatalog_memberRowUsesRealModelForImageCapability() throws {
        let defaultProfile = makeProfile(name: "GLM", key: "glm", model: "glm-5.3")
        let published = [
            makePublished(key: "glm", profileName: "GLM", model: "glm-5.3"),
            makePublished(key: "kimi", profileName: "Kimi", model: "kimi-k3")
        ]
        try store.writeAggregatedCatalog(defaultProfile: defaultProfile, published: published, defaultKey: "glm")

        let models = try readModels()
        let glmRow = try XCTUnwrap(models.first { ($0["slug"] as? String) == "glm-5.3" })
        let kimiRow = try XCTUnwrap(models.first { ($0["slug"] as? String) == "om-kimi/kimi-k3" })
        XCTAssertEqual(glmRow["input_modalities"] as? [String], ["text"])
        XCTAssertEqual(kimiRow["input_modalities"] as? [String], ["text", "image"])
    }
}
