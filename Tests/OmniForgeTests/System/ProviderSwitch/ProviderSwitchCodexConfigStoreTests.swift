import XCTest
@testable import OmniForge

/// Codex `config.toml` 字段所有权合并：model_providers 表写入、切 Official 删 override、TOML 往返。
final class ProviderSwitchCodexConfigStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConfigStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configURL = tmpDir.appendingPathComponent("config.toml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore() -> CodexConfigStore {
        CodexConfigStore(configURL: configURL)
    }

    private func makeProfile(
        name: String = "GLM",
        key: String = "glm",
        baseURL: String = "https://open.bigmodel.cn/api/paas/v4",
        token: String = "sk-glm",
        model: String? = "glm-4-7"
    ) -> ProviderProfile {
        ProviderProfile(
            id: key,
            name: name,
            tool: .codex,
            baseURL: baseURL,
            token: token,
            modelOverride: model,
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

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "chat"
        experimental_bearer_token = "sk-glm"
        """ + "\n")
    }

    func test_applyProfile_preservesUnrelatedContent() throws {
        try writeConfig("""
        # OpenAI API key configuration
        model = "gpt-5"
        model_reasoning_effort = "medium" # 推理强度
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
        model_reasoning_effort = "medium" # 推理强度
        temperature = 0.7
        model_provider = "glm"

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        env_key = "OPENAI_API_KEY"
        wire_api = "responses"

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        wire_api = "chat"
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
        try makeStore().applyProfile(makeProfile(name: "GLM 新"))
        XCTAssertEqual(try String(contentsOf: configURL), """
        model_provider = "glm"
        model = "glm-4-7"
        [model_providers.glm]
        name = "GLM 新"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        env_key = "GLM_API_KEY"
        extra_flag = true
        wire_api = "chat"
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
        wire_api = "chat"
        experimental_bearer_token = "sk-glm"
        """ + "\n")
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

        [model_providers.glm]
        name = "GLM"
        base_url = "https://open.bigmodel.cn/api/paas/v4"
        experimental_bearer_token = "sk-glm"

        [model_providers.kimi]
        name = "Kimi"
        """)
        try makeStore().clearOverrides()
        XCTAssertEqual(try String(contentsOf: configURL), """
        [model_providers.kimi]
        name = "Kimi"
        """ + "\n", "非激活的 kimi 表保留")
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
