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

    func test_removeCatalog_deletesFileIfExists() throws {
        try Data("{}".utf8).write(to: catalogURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        try store.removeCatalog()
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))

        // 文件不存在时再次调用不报错
        XCTAssertNoThrow(try store.removeCatalog())
    }
}
