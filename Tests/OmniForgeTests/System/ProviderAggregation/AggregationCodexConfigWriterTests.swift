import XCTest
@testable import OmniForge

/// Codex 聚合投影：custom provider 表与顶层键、登录态键按入参取舍、顶层窗口键剥除、
/// 用户表与内置 provider 保留、退出清理（含只删指向本机代理的 custom 表）、目录文件随写。
/// 官方默认（SPEC 3 / P0-3）：改写顶层 `openai_base_url`、不写 custom 表与目录、
/// 切换时摘掉旧的目录指针并删掉旧目录文件、退出时清掉 `openai_base_url`。
final class AggregationCodexConfigWriterTests: XCTestCase {
    private var tmpDir: URL!
    private var configURL: URL!
    private var catalogURL: URL!
    private var writer: AggregationCodexConfigWriter!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationCodexConfigWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configURL = tmpDir.appendingPathComponent("config.toml")
        catalogURL = tmpDir.appendingPathComponent("cc-switch-model-catalog.json")
        writer = AggregationCodexConfigWriter(configURL: configURL, catalogURL: catalogURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeConfig(_ text: String) throws {
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func readConfigDocument() throws -> TOMLFile {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        return try XCTUnwrap(TOMLFile.parse(text))
    }

    /// 默认供应商 fixture（DeepSeek，codexModels 首项为 deepseek-v4-pro）。
    private var deepseek: ProviderProfile {
        ProviderProfile(
            id: "deepseek",
            name: "DeepSeek",
            tool: .codex,
            baseURL: "https://api.deepseek.com/v1",
            token: "sk-ds",
            reasoningEffort: "high",
            codexModels: ["deepseek-v4-pro"],
            managedBy: ProviderProfile.managedByMarker
        )
    }

    private var kimiK3: AggregationPublishedModel {
        AggregationPublishedModel(
            key: "kimi",
            profileName: "Kimi",
            model: "kimi-k3",
            upstream: "kimi-k3",
            displayName: "Kimi K3",
            oneM: false,
            window: 256_000
        )
    }

    /// 官方 fixture（OpenAI）：登录走 `auth.json` OAuth，无静态 token。
    private var officialOpenAI: ProviderProfile {
        ProviderProfile(
            id: "openai",
            name: "OpenAI",
            tool: .codex,
            baseURL: "https://api.openai.com/v1",
            token: ""
        )
    }

    func test_applyAggregation_writesCustomProviderTableAndTopLevelKeys() throws {
        try writer.applyAggregation(defaultProfile: deepseek, published: [kimiK3], port: 15721, requiresOpenAIAuth: true)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("model_provider = \"custom\""))
        XCTAssertTrue(text.contains("model = \"deepseek-v4-pro\""))
        XCTAssertTrue(text.contains("model_catalog_json = \"cc-switch-model-catalog.json\""))
        XCTAssertTrue(text.contains("[model_providers.custom]"))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:15721/v1\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(text.contains("experimental_bearer_token = \"PROXY_MANAGED\""))
        XCTAssertTrue(text.contains("requires_openai_auth = true"))
    }

    func test_applyAggregation_omitsRequiresOpenAIAuthWhenNoLoginOnDisk() throws {
        try writer.applyAggregation(defaultProfile: deepseek, published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let doc = try readConfigDocument()
        XCTAssertNil(doc.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]))
    }

    func test_applyAggregation_stripsGlobalWindowKeysFromTopLevel() throws {
        try writeConfig("model_context_window = 999999\nmodel_auto_compact_token_limit = 888888\n")
        try writer.applyAggregation(defaultProfile: deepseek, published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "model_context_window", table: nil))
        XCTAssertNil(doc.stringValue(key: "model_auto_compact_token_limit", table: nil))
    }

    func test_applyAggregation_preservesUserTablesAndBuiltInProviders() throws {
        try writeConfig("""
        [model_providers.ollama_local]
        name = "Ollama"
        base_url = "http://localhost:11434/v1"

        [model_providers.openai]
        name = "OpenAI"
        base_url = "https://api.openai.com/v1"
        """)
        try writer.applyAggregation(defaultProfile: deepseek, published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[model_providers.ollama_local]"))
        XCTAssertTrue(text.contains("[model_providers.openai]"))
    }

    func test_clearAggregation_removesOwnedKeysAndCustomTableButKeepsBuiltIns() throws {
        try writeConfig("""
        model_provider = "custom"
        model = "deepseek-v4-pro"
        model_catalog_json = "cc-switch-model-catalog.json"

        [model_providers.custom]
        name = "custom"
        base_url = "http://127.0.0.1:15721/v1"

        [model_providers.openai]
        name = "OpenAI"
        """)
        try writer.clearAggregation()
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "model_provider", table: nil))
        XCTAssertNil(doc.stringValue(key: "model_catalog_json", table: nil))
        XCTAssertNil(doc.stringValue(key: "name", table: ["model_providers", "custom"]))
        XCTAssertEqual(doc.stringValue(key: "name", table: ["model_providers", "openai"]), "OpenAI")
    }

    func test_clearAggregation_keepsUserBuiltCustomTableNotPointingAtProxy() throws {
        try writeConfig("""
        [model_providers.custom]
        name = "my own gateway"
        base_url = "https://gateway.example.com/v1"
        """)
        try writer.clearAggregation()
        let doc = try readConfigDocument()
        XCTAssertEqual(doc.stringValue(key: "name", table: ["model_providers", "custom"]), "my own gateway")
    }

    func test_applyAggregation_writesCatalogFileAlongsideConfig() throws {
        try writer.applyAggregation(defaultProfile: deepseek, published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    func test_applyAggregation_officialDefaultWritesOpenAIBaseURLInsteadOfCustomTable() throws {
        try writer.applyAggregation(defaultProfile: officialOpenAI, published: [kimiK3], port: 15721,
                                    requiresOpenAIAuth: false, defaultIsOfficial: true)
        let doc = try readConfigDocument()
        XCTAssertEqual(doc.stringValue(key: "openai_base_url", table: nil), "http://127.0.0.1:15721/v1")
        XCTAssertNil(doc.stringValue(key: "model_provider", table: nil), "官方默认不写 custom 表（cc-switch codex.rs:462-467）")
        XCTAssertNil(doc.stringValue(key: "name", table: ["model_providers", "custom"]))
        XCTAssertNil(doc.stringValue(key: "model_catalog_json", table: nil), "官方默认拿不到官方模型行 → 目录整体不写（cc-switch codex_direct.rs:751-764）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    func test_applyAggregation_switchingToOfficialDefaultDropsStaleCatalogKeyAndFile() throws {
        // 先按第三方默认写一轮：目录指针 + 目录文件都在盘上。
        try writer.applyAggregation(defaultProfile: deepseek, published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        try writer.applyAggregation(defaultProfile: officialOpenAI, published: [kimiK3], port: 15721,
                                    requiresOpenAIAuth: false, defaultIsOfficial: true)
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "model_catalog_json", table: nil), "拥有键语义：切到官方默认时主动摘掉目录指针")
        XCTAssertNil(doc.stringValue(key: "model_provider", table: nil), "留着旧 provider 指向会让 Codex 绕过本机代理")
        XCTAssertNil(doc.stringValue(key: "name", table: ["model_providers", "custom"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path), "旧目录文件一并删除，否则 Codex 仍读旧目录")
    }

    func test_clearAggregation_removesOpenAIBaseURL() throws {
        try writer.applyAggregation(defaultProfile: officialOpenAI, published: [kimiK3], port: 15721,
                                    requiresOpenAIAuth: false, defaultIsOfficial: true)
        try writer.clearAggregation()
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "openai_base_url", table: nil), "官方路径退出后不得残留指向死端口的指针")
    }

    func test_projectedContractDigest_seesOfficialBranchAndMatchesDiskAfterApply() throws {
        try writer.applyAggregation(defaultProfile: officialOpenAI, published: [kimiK3], port: 15721,
                                    requiresOpenAIAuth: false, defaultIsOfficial: true)
        // 盘上现状固定为官方投影：两个分支的投影摘要必须分居它两侧。
        let officialDigest = writer.projectedContractDigest(
            defaultProfile: officialOpenAI, published: [kimiK3], port: 15721,
            requiresOpenAIAuth: false, defaultIsOfficial: true
        )
        let thirdPartyDigest = writer.projectedContractDigest(
            defaultProfile: officialOpenAI, published: [kimiK3], port: 15721,
            requiresOpenAIAuth: false, defaultIsOfficial: false
        )
        XCTAssertEqual(writer.currentContractDigest(), officialDigest, "官方分支落盘后闸门应判定「未变更」，不触发无谓重写")
        XCTAssertNotEqual(writer.currentContractDigest(), thirdPartyDigest, "同一份盘上现状，第三方摘要必须判「变了」——否则官方分支的投影变化对写前闸门不可见")
    }
}
