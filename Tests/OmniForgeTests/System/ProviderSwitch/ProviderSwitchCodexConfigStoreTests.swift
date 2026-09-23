import XCTest
@testable import OmniForge

/// Codex `config.toml` 字段所有权合并：model_providers 表写入、切 Official 删 override、TOML 往返。
final class ProviderSwitchCodexConfigStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var configURL: URL!

    private var catalogURL: URL!
    private var catalogStore: CodexModelCatalogStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConfigStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configURL = tmpDir.appendingPathComponent("config.toml")
        catalogURL = tmpDir.appendingPathComponent("omniforge-model-catalog.json")
        catalogStore = CodexModelCatalogStore(catalogURL: catalogURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore() -> CodexConfigStore {
        CodexConfigStore(configURL: configURL, catalogStore: catalogStore)
    }

    private func makeProfile(
        name: String = "GLM",
        key: String = "glm",
        baseURL: String = "https://open.bigmodel.cn/api/paas/v4",
        token: String = "sk-glm",
        model: String? = "glm-4-7",
        reasoningEffort: String? = nil
    ) -> ProviderProfile {
        ProviderProfile(
            id: key,
            name: name,
            tool: .codex,
            baseURL: baseURL,
            token: token,
            modelOverride: model,
            reasoningEffort: reasoningEffort,
            modelMapping: nil,
            extraEnv: [:],
            managedBy: ProviderProfile.managedByMarker
        )
    }

    private func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    // MARK: - 写入

    func test_applyProfile_createsMinimalFileWhenMissing() throws {
        try makeStore().applyProfile(makeProfile())
        let text = try String(contentsOf: configURL)
        XCTAssertEqual(text, """
        model_provider = "glm"
        model = "glm-4-7"
        model_catalog_json = "omniforge-model-catalog.json"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "sk-glm"
        """ + "\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    func test_applyProfile_withReasoningEffort() throws {
        try makeStore().applyProfile(makeProfile(reasoningEffort: "medium"))
        let text = try String(contentsOf: configURL)
        XCTAssertEqual(text, """
        model_provider = "glm"
        model = "glm-4-7"
        model_catalog_json = "omniforge-model-catalog.json"
        model_reasoning_effort = "medium"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "sk-glm"
        """ + "\n")

        // 验证 catalog json 中的默认思考等级为 medium
        let catalogData = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["default_reasoning_level"] as? String, "medium")
    }

    /// 回归（R01）：无空格合法 TOML 上完整 applyProfile 链（插入 provider → 更新 model）
    /// 曾把行号推出文件末尾导致越界；必须成功且未知字段不丢失。
    /// 行级原样保留契约：原地更新沿用原文词法（无空格风格不变）。
    func test_applyProfile_noSpaceOriginalCompletesAndKeepsUnknownFields() throws {
        try writeConfig("model=\"old\"\nnotify=[\"iTerm2\"]\n")
        try makeStore().applyProfile(makeProfile())
        let text = try String(contentsOf: configURL)

        XCTAssertEqual(text, """
        model="glm-4-7"
        notify=["iTerm2"]
        model_provider = "glm"
        model_catalog_json = "omniforge-model-catalog.json"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "sk-glm"
        """ + "\n")

        // 落盘结果再读回：激活 provider 与凭证一致。
        let (key, baseURL, token) = try makeStore().readActiveProvider()
        XCTAssertEqual(key, "glm")
        XCTAssertEqual(baseURL, "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(token, "sk-glm")
    }

    func test_applyProfile_preservesUnrelatedContent() throws {
        try writeConfig("""
        # OpenAI API key configuration
        model = "gpt-5"
        temperature = 0.7

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"
        """)
        try makeStore().applyProfile(makeProfile())
        XCTAssertEqual(try String(contentsOf: configURL), """
        # OpenAI API key configuration
        model = "glm-4-7"
        temperature = 0.7
        model_provider = "glm"
        model_catalog_json = "omniforge-model-catalog.json"

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "sk-glm"
        """ + "\n")
    }

    func test_applyProfile_updatesExistingTableOnlyOwnedKeys() throws {
        try writeConfig("""
        [model_providers.glm]
        name = "旧名字"
        base_url = "https://old.example"
        env_key = "GLM_API_KEY"
        extra_flag = true
        """ )
        try makeStore().applyProfile(makeProfile(name: "GLM"))
        XCTAssertEqual(try String(contentsOf: configURL), """
        model_provider = "glm"
        model = "glm-4-7"
        model_catalog_json = "omniforge-model-catalog.json"
        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        env_key = "GLM_API_KEY"
        extra_flag = true
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "sk-glm"
        """ + "\n", "env_key 等非拥有键保留，拥有键原地更新/追加")
    }

    func test_applyProfile_withoutModelOverrideLeavesModelUntouched() throws {
        try writeConfig("model = \"gpt-5\"\n")
        try makeStore().applyProfile(makeProfile(model: nil))
        XCTAssertEqual(try String(contentsOf: configURL), """
        model = "gpt-5"
        model_provider = "glm"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "sk-glm"
        """ + "\n")
    }

    /// 多模型：首位写 config.toml 顶层 model（默认模型），全部条目进入模型目录。
    func test_applyProfile_multipleModels_writesFirstAsDefaultAndFullCatalog() throws {
        let profile = ProviderProfile(
            id: "glm",
            name: "GLM",
            tool: .codex,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            token: "sk-glm",
            codexModels: ["glm-5.3", "glm-4.7-air"],
            managedBy: ProviderProfile.managedByMarker
        )
        try makeStore().applyProfile(profile)

        let text = try String(contentsOf: configURL)
        XCTAssertTrue(text.contains("model = \"glm-5.3\""), "首位为默认模型")
        XCTAssertTrue(text.contains("model_catalog_json = \"omniforge-model-catalog.json\""))

        let catalogData = try Data(contentsOf: catalogURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["slug"] as? String }, ["glm-5.3", "glm-4.7-air"])
    }

    func test_applyProfile_tokenEscapingRoundTrip() throws {
        let trickyToken = "sk-a\"b\\c\n中#文"
        try makeStore().applyProfile(makeProfile(token: trickyToken))
        let document = try XCTUnwrap(TOMLFile.parse(String(contentsOf: configURL)))
        XCTAssertEqual(
            document.stringValue(key: "experimental_bearer_token", table: ["model_providers", "glm"]),
            trickyToken
        )
    }

    // MARK: - 读取激活态

    func test_readActiveProvider_missingFileReturnsNilNil() throws {
        let active = try makeStore().readActiveProvider()
        XCTAssertNil(active.key)
        XCTAssertNil(active.baseURL)
    }

    func test_readActiveProvider_returnsKeyAndBaseURL() throws {
        try writeConfig("""
        model_provider = "glm"

        [model_providers.glm]
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        """)
        let active = try makeStore().readActiveProvider()
        XCTAssertEqual(active.key, "glm")
        XCTAssertEqual(active.baseURL, "https://open.bigmodel.cn/api/paas/v4")
    }

    func test_readActiveProvider_builtInOpenAIIsNilBaseURLForTopLevelOnly() throws {
        try writeConfig("model_provider = \"openai\"\n")
        let active = try makeStore().readActiveProvider()
        XCTAssertEqual(active.key, "openai")
        XCTAssertNil(active.baseURL, "无对应表 → base_url 为 nil")
    }

    // MARK: - 切 Official

    func test_clearOverrides_removesTopLevelAndProviderTable() throws {
        try writeConfig("""
        model_provider = "glm"
        model = "glm-4-7"
        model_catalog_json = "omniforge-model-catalog.json"
        model_reasoning_effort = "high"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        experimental_bearer_token = "sk-glm"

        [model_providers.kimi]
        name = "Kimi"
        """)
        try Data("{}".utf8).write(to: catalogURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        try makeStore().clearOverrides()
        XCTAssertEqual(try String(contentsOf: configURL), """
        [model_providers.kimi]
        name = "Kimi"
        """ + "\n", "非激活的 kimi 表保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path), "模型目录文件被清理")
    }

    func test_clearOverrides_keepsBuiltInTable() throws {
        try writeConfig("""
        model_provider = "openai"
        model = "gpt-5"

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"
        """)
        try makeStore().clearOverrides()
        XCTAssertEqual(try String(contentsOf: configURL), """
        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"
        """ + "\n", "内置 openai 表是 CLI 自身登录配置，不删")
    }

    func test_clearOverrides_missingFileIsNoop() throws {
        XCTAssertNoThrow(try makeStore().clearOverrides())
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    // MARK: - 健壮性

    func test_corruptedToml_abortsWithoutWrite() throws {
        try writeConfig("model = \"unterminated\n")
        let store = makeStore()
        XCTAssertThrowsError(try store.applyProfile(makeProfile())) { error in
            XCTAssertEqual(error as? ProviderConfigFileError, .corrupted(path: configURL.path))
        }
        XCTAssertThrowsError(try store.readActiveProvider())
        XCTAssertEqual(try String(contentsOf: configURL), "model = \"unterminated\n", "文件未被改写")
    }

    func test_applyProfile_writesWith0600Permissions() throws {
        try makeStore().applyProfile(makeProfile())
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }
}
