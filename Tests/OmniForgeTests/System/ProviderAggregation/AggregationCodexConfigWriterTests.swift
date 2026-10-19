import XCTest
@testable import OmniForge

/// Codex 聚合投影：custom provider 表与顶层键、登录态键按入参取舍、顶层窗口键剥除、
/// 用户表与内置 provider 保留、退出清理（含只删指向本机代理的 custom 表）、目录文件随写。
/// 官方默认（SPEC 3 / P0-3）：改写顶层 `openai_base_url`、不写 custom 表与目录、
/// 切换时摘掉旧的目录指针并删掉旧目录文件、退出时清掉 `openai_base_url`。
/// 凭证形态随默认那家切换（2026-10-19 401 修复）：第三方写占位 token 供代理替换，
/// 官方**不写** token——codex-rs 里 `experimental_bearer_token` 优先于
/// `requires_openai_auth`，写占位符会让 Codex 永不带 auth.json 的 OAuth。
final class AggregationCodexConfigWriterTests: XCTestCase {
    private var tmpDir: URL!
    private var configURL: URL!
    private var catalogURL: URL!
    private var modelsCacheURL: URL!
    private var writer: AggregationCodexConfigWriter!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationCodexConfigWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        configURL = tmpDir.appendingPathComponent("config.toml")
        catalogURL = tmpDir.appendingPathComponent("omniforge-stack-catalog.json")
        modelsCacheURL = tmpDir.appendingPathComponent(ProviderSwitchPaths.codexModelsCacheFileName)
        writer = AggregationCodexConfigWriter(configURL: configURL, catalogURL: catalogURL, modelsCacheURL: modelsCacheURL)
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

    /// 官方 fixture（OpenAI）：登录走 `auth.json` OAuth，无静态 token；
    /// `codexModels` 对齐合成官方卡（来自 models_cache 的 slug 列表）。
    private var officialOpenAI: ProviderProfile {
        ProviderProfile(
            id: "openai",
            name: "OpenAI",
            tool: .codex,
            baseURL: "https://api.openai.com/v1",
            token: "",
            codexModels: ["gpt-5.6-sol"]
        )
    }

    /// 第三方默认形状：占位 token 由代理按目标替换为真实凭证；登录不在场故不写
    /// `requires_openai_auth`（写了会让 Codex 回退拿 auth.json 打第三方地址）。
    func test_applyAggregation_writesCustomProviderTableAndTopLevelKeys() throws {
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("model_provider = \"custom\""))
        XCTAssertTrue(text.contains("model = \"deepseek-v4-pro\""))
        XCTAssertTrue(text.contains("model_catalog_json = \"omniforge-stack-catalog.json\""))
        XCTAssertTrue(text.contains("[model_providers.custom]"))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:15721/v1\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(text.contains("experimental_bearer_token = \"PROXY_MANAGED\""))
        XCTAssertFalse(text.contains("requires_openai_auth"), "登录不在场 → 不写 OAuth 回退指令")
    }

    func test_applyAggregation_omitsRequiresOpenAIAuthWhenNoLoginOnDisk() throws {
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let doc = try readConfigDocument()
        XCTAssertNil(doc.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]))
    }

    /// 旧版聚合目录（对齐 cc-switch 时期的文件名）在投影时自愈删除——config 已不再指向它，
    /// 残留只会误导排查。
    func test_applyAggregation_removesLegacyCatalogFile() throws {
        let legacyURL = tmpDir.appendingPathComponent(ProviderSwitchPaths.legacyCodexAggregationCatalogFileName)
        try "{}".write(to: legacyURL, atomically: true, encoding: .utf8)
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "旧版目录文件应被自愈删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path), "现行目录文件应正常写入")
    }

    func test_applyAggregation_stripsGlobalWindowKeysFromTopLevel() throws {
        try writeConfig("model_context_window = 999999\nmodel_auto_compact_token_limit = 888888\n")
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "model_context_window", table: nil))
        XCTAssertNil(doc.stringValue(key: "model_auto_compact_token_limit", table: nil))
    }

    // MARK: - Codex 客户端行为键从默认供应商行照搬（cc-switch #8265 / #8338）

    /// 行里配的重试/流超时/远程压缩搬进 custom 表——聚合指向 custom 后不搬就全部失效。
    func test_applyAggregation_copiesClientBehaviorKeysFromDefaultProviderRow() throws {
        try writeConfig("""
        [model_providers.deepseek]
        name = "DeepSeek"
        base_url = "https://api.deepseek.com/v1"
        stream_max_retries = 50
        stream_idle_timeout_ms = 300000
        [model_providers.deepseek.capabilities]
        remote_compaction = "v2"
        """)
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let doc = try readConfigDocument()
        let custom = ["model_providers", "custom"]
        XCTAssertEqual(doc.stringValue(key: "stream_max_retries", table: custom), "50")
        XCTAssertEqual(doc.stringValue(key: "stream_idle_timeout_ms", table: custom), "300000")
        XCTAssertNil(doc.stringValue(key: "request_max_retries", table: custom), "行里没配的键不凭空出现")
        XCTAssertEqual(
            doc.rawValue(key: "remote_compaction", table: custom + ["capabilities"]),
            "\"v2\"",
            "远程压缩偏好原字面量照搬（字符串/布尔形态都兼容）"
        )
    }

    /// 行里没配这些键 → custom 表的残留照摘（换默认后上一家的配置不得留在共享表里）。
    func test_applyAggregation_removesStaleClientBehaviorKeysWhenRowHasNone() throws {
        try writeConfig("""
        [model_providers.deepseek]
        name = "DeepSeek"
        base_url = "https://api.deepseek.com/v1"

        [model_providers.custom]
        name = "custom"
        base_url = "http://127.0.0.1:15721/v1"
        stream_max_retries = 50
        [model_providers.custom.capabilities]
        remote_compaction = "v2"
        """)
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let doc = try readConfigDocument()
        let custom = ["model_providers", "custom"]
        XCTAssertNil(doc.stringValue(key: "stream_max_retries", table: custom))
        XCTAssertNil(doc.stringValue(key: "request_max_retries", table: custom))
        XCTAssertNil(doc.stringValue(key: "stream_idle_timeout_ms", table: custom))
        XCTAssertNil(doc.stringValue(key: "remote_compaction", table: custom + ["capabilities"]))
        XCTAssertFalse(doc.hasEntries(in: custom + ["capabilities"]), "摘键后空表应连表头一起摘掉")
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
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[model_providers.ollama_local]"))
        XCTAssertTrue(text.contains("[model_providers.openai]"))
    }

    func test_clearAggregation_removesOwnedKeysAndCustomTableButKeepsBuiltIns() throws {
        try writeConfig("""
        model_provider = "custom"
        model = "deepseek-v4-pro"
        model_catalog_json = "omniforge-stack-catalog.json"

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
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    // MARK: - 官方默认与第三方同形状（SPEC 2026-10-17 方案 B，推翻 P0-3）

    /// 官方默认：custom 表 + requires_openai_auth + 目录（官方行来自 models_cache 原样行）。
    func test_applyAggregation_officialDefaultUsesSameProxyShapeAsThirdParty() throws {
        try writeModelsCache()
        let officialPublished = AggregationPublishedModel(
            key: "openai", profileName: "OpenAI",
            model: "gpt-5.6-sol", upstream: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol", oneM: false, window: 272_000
        )
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        let doc = try readConfigDocument()
        XCTAssertEqual(doc.stringValue(key: "model_provider", table: nil), "custom", "官方与第三方同形状：请求经本机代理")
        XCTAssertNil(doc.stringValue(key: "openai_base_url", table: nil), "P0-3 旧官方分支的指针键不再写")
        XCTAssertEqual(doc.stringValue(key: "model_catalog_json", table: nil), ProviderSwitchPaths.codexAggregationCatalogFileName)
        XCTAssertEqual(doc.stringValue(key: "base_url", table: ["model_providers", "custom"]), "http://127.0.0.1:15721/v1")
        XCTAssertEqual(doc.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]), true, "OAuth 凭证由 Codex 附带，代理 passthrough 透传")
        XCTAssertEqual(doc.stringValue(key: "model", table: nil), "gpt-5.6-sol")

        // 目录：官方行原样（保留官方 base_instructions）在前 + 成员行带 om- 前缀在后。
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let models = try XCTUnwrap(catalog?["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["slug"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(models[0]["base_instructions"] as? String, "OFFICIAL_INSTRUCTIONS", "官方行不套中性模板")
        XCTAssertEqual(models[1]["slug"] as? String, "om-kimi/kimi-k3")
        XCTAssertEqual(models[1]["comp_hash"] as? String, "om")
    }

    /// 官方默认：**不写** `experimental_bearer_token`。codex-rs 的
    /// `resolve_provider_auth` 里 bearer token 优先于 `requires_openai_auth`，
    /// 写了占位符 Codex 就永不带 auth.json 的 OAuth，官方上游每个请求都 401
    /// （2026-10-19 实测：`Incorrect API key provided: PROXY_MA*AGED`）。
    func test_applyAggregation_officialDefaultOmitsBearerTokenSoCodexAttachesOAuth() throws {
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        let doc = try readConfigDocument()
        let custom = ["model_providers", "custom"]
        XCTAssertNil(doc.stringValue(key: "experimental_bearer_token", table: custom), "官方默认不得写占位凭证")
        XCTAssertEqual(doc.booleanValue(key: "requires_openai_auth", table: custom), true, "OAuth 由 Codex 附带")
        XCTAssertEqual(doc.stringValue(key: "base_url", table: custom), "http://127.0.0.1:15721/v1")
    }

    /// 第三方 → 官方默认切换：上一家留下的占位 token 必须摘掉。
    /// 只判「不写」不够——磁盘上已有那个键，投影不显式移除就残留。
    func test_applyAggregation_switchingToOfficialDefaultRemovesStaleBearerToken() throws {
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertNotNil(try readConfigDocument().stringValue(key: "experimental_bearer_token", table: ["model_providers", "custom"]))

        let officialPublished = AggregationPublishedModel(
            key: "openai", profileName: "OpenAI",
            model: "gpt-5.6-sol", upstream: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol", oneM: false, window: 272_000
        )
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        XCTAssertNil(
            try readConfigDocument().stringValue(key: "experimental_bearer_token", table: ["model_providers", "custom"]),
            "切换默认后旧占位凭证不得留在共享 custom 表里"
        )
    }

    /// 官方 → 第三方默认切换：占位 token 必须补上（代理按目标替换）。
    func test_applyAggregation_switchingToThirdPartyDefaultWritesBearerToken() throws {
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertEqual(
            try readConfigDocument().stringValue(key: "experimental_bearer_token", table: ["model_providers", "custom"]),
            "PROXY_MANAGED"
        )
    }

    /// 官方缓存缺失 → 安全降级：官方行不进目录，成员行照常，custom 表照写。
    func test_applyAggregation_officialDefaultWithoutCacheDegradesGracefully() throws {
        // 不写 models_cache（tmpDir 里本就没有）。
        let officialPublished = AggregationPublishedModel(
            key: "openai", profileName: "OpenAI",
            model: "gpt-5.6-sol", upstream: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol", oneM: false, window: 272_000
        )
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let models = try XCTUnwrap(catalog?["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 1, "官方行缺失只留成员行")
        XCTAssertEqual(models[0]["slug"] as? String, "om-kimi/kimi-k3")
    }

    /// 第三方 → 官方默认切换：旧 openai_base_url 残留被摘，目录换成官方行 + 成员行。
    func test_applyAggregation_switchingToOfficialDefaultRewritesCatalogInPlace() throws {
        try writeModelsCache()
        try writeConfig("openai_base_url = \"http://127.0.0.1:99999/v1\"\n")
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        let officialPublished = AggregationPublishedModel(
            key: "openai", profileName: "OpenAI",
            model: "gpt-5.6-sol", upstream: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol", oneM: false, window: 272_000
        )
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "openai_base_url", table: nil), "旧官方形态的指针键随投影自愈摘除")
        XCTAssertEqual(doc.stringValue(key: "model_provider", table: nil), "custom")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let models = try XCTUnwrap(catalog?["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["slug"] as? String, "gpt-5.6-sol", "官方行替换旧目录内容")
    }

    func test_clearAggregation_removesOpenAIBaseURL() throws {
        try writeConfig("openai_base_url = \"http://127.0.0.1:15721/v1\"\n")
        try writer.clearAggregation()
        let doc = try readConfigDocument()
        XCTAssertNil(doc.stringValue(key: "openai_base_url", table: nil), "官方路径退出后不得残留指向死端口的指针")
    }

    func test_projectedContractDigest_matchesDiskAfterOfficialApply() throws {
        try writeModelsCache()
        let officialPublished = AggregationPublishedModel(
            key: "openai", profileName: "OpenAI",
            model: "gpt-5.6-sol", upstream: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol", oneM: false, window: 272_000
        )
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        let digest = writer.projectedContractDigest(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        XCTAssertEqual(writer.currentContractDigest(), digest, "官方分支落盘后闸门应判定「未变更」，不触发无谓重写")
        // 官方行与写盘同源：models_cache 变了 → 摘要必须判「变了」。
        try writeModelsCache(baseInstructions: "CHANGED_INSTRUCTIONS")
        let changedDigest = writer.projectedContractDigest(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        XCTAssertNotEqual(digest, changedDigest, "官方缓存行变化对写前闸门必须可见")
    }

    /// 存量自愈闸门：磁盘上带着占位 token 的官方投影（401 根因形态），
    /// 与官方投影的摘要必须判「变了」——否则启动自愈不会重写，病态配置永驻。
    func test_projectedContractDigest_detectsStalePlaceholderTokenOnDisk() throws {
        try writeModelsCache()
        let officialPublished = AggregationPublishedModel(
            key: "openai", profileName: "OpenAI",
            model: "gpt-5.6-sol", upstream: "gpt-5.6-sol",
            displayName: "GPT 5.6 Sol", oneM: false, window: 272_000
        )
        // 病态磁盘：旧形状（占位 token + requires_openai_auth 同时在场）。
        try writeConfig("""
        model_provider = "custom"
        model_catalog_json = "omniforge-stack-catalog.json"

        [model_providers.custom]
        name = "custom"
        base_url = "http://127.0.0.1:15721/v1"
        wire_api = "responses"
        experimental_bearer_token = "PROXY_MANAGED"
        requires_openai_auth = true
        """)
        let projected = writer.projectedContractDigest(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        XCTAssertNotEqual(writer.currentContractDigest(), projected, "病态磁盘必须判「变了」以触发自愈重写")
        // 重写后落到无占位 token 的形状，摘要随即一致（不会反复重写）。
        try writer.applyAggregation(
            defaultProfile: officialOpenAI, defaultKey: "openai",
            published: [officialPublished, kimiK3], port: 15721, requiresOpenAIAuth: true
        )
        XCTAssertEqual(writer.currentContractDigest(), projected)
    }

    /// 第三方形状同样必须写后摘要一致：`recoverOnLaunch` 每次面板挂载都判变，
    /// 摘要不稳会反复重写用户配置。带一个用户自有键，顺带验合并保留。
    func test_projectedContractDigest_matchesDiskAfterThirdPartyApply() throws {
        try writeConfig("model_verbosity = \"low\"\n")
        try writer.applyAggregation(defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false)
        let digest = writer.projectedContractDigest(
            defaultProfile: deepseek, defaultKey: "deepseek", published: [kimiK3], port: 15721, requiresOpenAIAuth: false
        )
        XCTAssertEqual(writer.currentContractDigest(), digest, "落盘后闸门应判定「未变更」")
        XCTAssertEqual(try readConfigDocument().stringValue(key: "model_verbosity", table: nil), "low", "用户自有键不受投影影响")
    }

    /// 写一份最小官方 models_cache（tmpDir 内，不碰真实 ~/.codex）。
    private func writeModelsCache(baseInstructions: String = "OFFICIAL_INSTRUCTIONS") throws {
        let root: [String: Any] = [
            "models": [[
                "slug": "gpt-5.6-sol",
                "display_name": "GPT 5.6 Sol",
                "base_instructions": baseInstructions,
                "context_window": 272_000,
                "max_context_window": 272_000,
                "auto_compact_token_limit": 244_800,
                "priority": 1,
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: modelsCacheURL)
    }
}
