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
