import XCTest
@testable import OmniForge

/// profile 文件管理：CCQ 兼容路径、撞名拒绝、外部文件列入、收编、双格式往返。
final class ProviderSwitchProfileStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var claudeDir: URL!
    private var codexDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderSwitchProfileStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        claudeDir = tmpDir.appendingPathComponent("providers")
        codexDir = tmpDir.appendingPathComponent("codex")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore() -> ProviderProfileStore {
        ProviderProfileStore(claudeProfileDirectory: claudeDir, codexProfileDirectory: codexDir)
    }

    private func makeProfile(
        id: String,
        name: String,
        tool: ProviderTool = .claudeCode,
        baseURL: String = "https://open.bigmodel.cn/api/anthropic",
        token: String = "sk-glm",
        model: String? = "glm-5.3"
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            tool: tool,
            baseURL: baseURL,
            token: token,
            modelOverride: model,
            modelMapping: nil,
            extraEnv: [:],
            managedBy: ProviderProfile.managedByMarker
        )
    }

    // MARK: - 新增 / 编辑

    func test_upsert_writesManagedJSONWithMarker() throws {
        try makeStore().upsert(makeProfile(id: "", name: "GLM"))
        let url = claudeDir.appendingPathComponent("glm.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(root["_managedBy"] as? String, "omniforge")
        XCTAssertNil(root["token"], "新格式凭证写在 env 内，不在根")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-glm")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "glm-5.3")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func test_upsert_editSameProfileOverwrites() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM"))
        try store.upsert(makeProfile(id: "glm", name: "GLM", token: "sk-new"))
        let listed = store.list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].token, "sk-new")
    }

    func test_upsert_renameMovesFileAndDeletesOldCopy() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM"))
        try store.upsert(makeProfile(id: "glm", name: "GLM Pro"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("glm.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("glm-pro.json").path))
        XCTAssertEqual(store.list(for: .claudeCode).map(\.id), ["glm-pro"])
    }

    func test_upsert_nameConflictRejected() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM"))
        // 另一个档案也叫 GLM（slug 撞名）→ 拒绝
        XCTAssertThrowsError(
            try store.upsert(makeProfile(id: "kimi", name: "GLM"))
        ) { error in
            XCTAssertEqual(error as? ProviderProfileStoreError, .nameConflict(key: "glm"))
        }
        XCTAssertEqual(store.list(for: .claudeCode).map(\.id), ["glm"], "原文件未被覆盖")
    }

    // MARK: - 列举与外部文件

    func test_list_emptyDirectory() {
        XCTAssertEqual(makeStore().list(for: .claudeCode), [])
        XCTAssertEqual(makeStore().list(for: .codex), [])
    }

    func test_list_includesForeignFilesWithBestEffortFields() throws {
        let foreign = claudeDir.appendingPathComponent("ccq-glm.json")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "name": "CCQ GLM",
            "baseUrl": "https://open.bigmodel.cn/api/anthropic",
            "apiKey": "sk-ccq",
        ]).write(to: foreign)

        let listed = makeStore().list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "ccq-glm")
        XCTAssertEqual(listed[0].name, "CCQ GLM")
        XCTAssertEqual(listed[0].baseURL, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(listed[0].token, "sk-ccq")
        XCTAssertNil(listed[0].managedBy, "外部文件无 _managedBy 标记")
        XCTAssertTrue(listed[0].hasCompleteConnection)
    }

    func test_list_includesUnparseableFilesWithIncompleteConnection() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data("{\"unrelated\": true}".utf8).write(to: claudeDir.appendingPathComponent("weird.json"))

        let listed = makeStore().list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "weird")
        XCTAssertEqual(listed[0].name, "weird")
        XCTAssertFalse(listed[0].hasCompleteConnection, "无连接参数 → 不可直接激活")
    }

    func test_list_roundTripsManagedProfile() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM", model: "glm-5.3"))
        let listed = store.list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].name, "GLM")
        XCTAssertEqual(listed[0].tool, .claudeCode)
        XCTAssertEqual(listed[0].baseURL, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(listed[0].token, "sk-glm")
        XCTAssertEqual(listed[0].modelOverride, "glm-5.3")
        XCTAssertEqual(listed[0].managedBy, "omniforge")
        XCTAssertTrue(listed[0].isManagedByOmniForge)
    }

    func test_list_roundTripsModelMappingAndExtraEnv() throws {
        let store = makeStore()
        try store.upsert(ProviderProfile(
            id: "",
            name: "DeepSeek",
            tool: .claudeCode,
            baseURL: "https://api.deepseek.com/anthropic",
            token: "sk-ds",
            modelOverride: "deepseek-v4-pro",
            modelMapping: ProviderModelMapping(
                sonnet: nil, sonnetName: nil, opus: nil, opusName: nil,
                fable: nil, fableName: nil, haiku: "deepseek-v4-flash", haikuName: nil, subagent: nil
            ),
            extraEnv: ["CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"],
            managedBy: "omniforge"
        ))
        let listed = store.list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].modelOverride, "deepseek-v4-pro")
        XCTAssertEqual(listed[0].modelMapping?.haiku, "deepseek-v4-flash")
        XCTAssertEqual(
            listed[0].extraEnv,
            ["CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"]
        )
    }

    func test_decode_oldFormatMapsSmallFastModelToHaiku() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let old = claudeDir.appendingPathComponent("glm.json")
        try JSONSerialization.data(withJSONObject: [
            "name": "GLM",
            "tool": "claudeCode",
            "baseURL": "https://open.bigmodel.cn/api/anthropic",
            "token": "sk-glm",
            "modelOverride": "glm-4-7",
            "smallFastModelOverride": "glm-4-flash",
            "_managedBy": "omniforge",
        ]).write(to: old)

        let listed = makeStore().list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].modelOverride, "glm-4-7")
        XCTAssertEqual(listed[0].modelMapping?.haiku, "glm-4-flash", "旧小模型映射到 Haiku")
        XCTAssertEqual(listed[0].modelMapping?.sonnet, nil)
        XCTAssertEqual(listed[0].managedBy, "omniforge")
    }

    func test_decode_envStyleExternalProfileReadsModelsAndExtraEnv() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let external = claudeDir.appendingPathComponent("ccq-deepseek.json")
        try JSONSerialization.data(withJSONObject: [
            "env": [
                "ANTHROPIC_AUTH_TOKEN": "sk-ccq",
                "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
                "ANTHROPIC_MODEL": "deepseek-v4-pro",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
                "CLAUDE_CODE_EFFORT_LEVEL": "max",
            ],
        ]).write(to: external)

        let listed = makeStore().list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "ccq-deepseek")
        XCTAssertEqual(listed[0].baseURL, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(listed[0].token, "sk-ccq")
        XCTAssertEqual(listed[0].modelOverride, "deepseek-v4-pro")
        XCTAssertEqual(listed[0].modelMapping?.haiku, "deepseek-v4-flash")
        XCTAssertEqual(listed[0].extraEnv, ["CLAUDE_CODE_EFFORT_LEVEL": "max"])
        XCTAssertNil(listed[0].managedBy, "外部 env 风格文件无 _managedBy 标记")
        XCTAssertTrue(listed[0].hasCompleteConnection)
    }

    // MARK: - Codex TOML 档案

    func test_codexProfile_roundTripsTOML() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM", tool: .codex, baseURL: "https://open.bigmodel.cn/api/paas/v4", model: nil))
        let url = codexDir.appendingPathComponent("glm.config.toml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("base_url = \"https://open.bigmodel.cn/api/paas/v4\""))
        XCTAssertTrue(text.contains("_managedBy = \"omniforge\""))

        let listed = store.list(for: .codex)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "glm")
        XCTAssertEqual(listed[0].tool, .codex)
        XCTAssertEqual(listed[0].baseURL, "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(listed[0].token, "sk-glm")
        XCTAssertEqual(listed[0].managedBy, "omniforge")
    }

    func test_codexProfile_tokenWithSpecialCharsRoundTrips() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM", tool: .codex, token: "sk-a\"b\\c\n中#文"))
        let listed = store.list(for: .codex)
        XCTAssertEqual(listed[0].token, "sk-a\"b\\c\n中#文")
    }

    // MARK: - 删除 / 收编

    func test_delete_removesFile() throws {
        let store = makeStore()
        try store.upsert(makeProfile(id: "", name: "GLM"))
        let listed = store.list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        try store.delete(listed[0])
        XCTAssertEqual(store.list(for: .claudeCode), [])
    }

    func test_adopt_createsProfileFromUnmanagedValues() throws {
        let store = makeStore()
        let profile = try store.adopt(
            name: "手改供应商",
            tool: .claudeCode,
            baseURL: "https://manual.example",
            token: "sk-manual",
            modelOverride: nil
        )
        XCTAssertEqual(profile.profileKey, "profile")
        let listed = store.list(for: .claudeCode)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].baseURL, "https://manual.example")
        XCTAssertEqual(listed[0].token, "sk-manual")
        XCTAssertEqual(listed[0].managedBy, "omniforge")
    }
}
