import XCTest
@testable import OmniForge

/// Claude Code 聚合投影：modelPicker 落顶层、四档别名共享 Stack id（1M 模型四档都带标记）、
/// 不写 ANTHROPIC_MODEL/子代理键、代理裸 origin + 占位凭证、MAX 窗口取非 1M 最小值、
/// 只动拥有键、退出清理、窗口缩写、发布源顺序。
/// 空发布（用户主动清空 stackModels）时不写 modelPicker，四档别名回落默认那家直连口径。
final class AggregationClaudeConfigWriterTests: XCTestCase {
    private var tmpDir: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationClaudeConfigWriterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        settingsURL = tmpDir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private var writer: AggregationClaudeConfigWriter {
        AggregationClaudeConfigWriter(settingsURL: settingsURL)
    }

    private func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - fixtures

    private func makePublished(
        key: String,
        profileName: String = "Kimi For Coding",
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

    /// 默认供应商 fixture（Kimi）。
    private var kimi: ProviderProfile {
        ProviderProfile(
            id: "kimi",
            name: "Kimi For Coding",
            tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding",
            token: "sk-kimi",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
        )
    }

    /// 默认供应商 fixture（智谱，1M）。
    private var zhipu1M: ProviderProfile {
        ProviderProfile(
            id: "zhipu",
            name: "Zhipu",
            tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-zhipu",
            stackModels: [ClaudeStackModel(model: "glm-5.2[1M]", displayName: "GLM 5.2", oneM: false)],
            extraEnv: ["CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1000000"]
        )
    }

    private var kimiK3: AggregationPublishedModel {
        makePublished(key: "kimi", model: "k3", upstream: "k3", displayName: "Kimi K3", window: 256_000)
    }

    private var zhipuGLM: AggregationPublishedModel {
        makePublished(
            key: "zhipu",
            profileName: "Zhipu",
            model: "glm-5.2",
            upstream: "glm-5.2[1M]",
            displayName: "GLM 5.2",
            window: 1_000_000,
            oneM: true
        )
    }

    // MARK: - modelPicker 落在顶层而非 env

    func test_applyAggregation_writesModelPickerAtTopLevelNotInsideEnv() throws {
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let root = try readSettings()
        let picker = try XCTUnwrap(root["modelPicker"] as? [String: Any])
        XCTAssertEqual(picker["replaceBuiltInOptions"] as? Bool, true)
        let options = try XCTUnwrap(picker["options"] as? [[String: Any]])
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0]["model"] as? String, "om-claude-kimi--k3")
        XCTAssertEqual(options[0]["label"] as? String, "Kimi K3（Kimi For Coding）")
        XCTAssertEqual(options[0]["description"] as? String, "k3 · 256K")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertNil(env["modelPicker"])
    }

    // MARK: - 空发布（用户主动清空 stackModels）

    func test_applyAggregation_emptyPublishedOmitsModelPickerButKeepsDirectAliases() throws {
        let ds = ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
            modelOverride: "k3-main",
            modelMapping: ProviderModelMapping(sonnet: "k3-sonnet", sonnetName: "Kimi Sonnet"),
            stackModels: []   // 主动清空 → 空发布
        )
        try writeSettings(["modelPicker": ["replaceBuiltInOptions": false, "options": [["model": "mine"]]]])
        try writer.applyAggregation(defaultProfile: ds, published: [], port: 15721)
        let root = try readSettings()
        XCTAssertNil(root["modelPicker"], "空发布不写 modelPicker——选择器保持内置模型（cc-switch controller.rs:226-228）")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        // 空发布时四档别名回落默认那家映射的直连口径（cc-switch claude.rs:257-260 None → proxy_model_fields）
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "k3-main")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "k3-sonnet")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] as? String, "Kimi Sonnet")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:15721", "代理仍生效")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "PROXY_MANAGED")
        XCTAssertNil(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "默认那家 extraEnv 无窗口值时不写")
    }

    // MARK: - 四档别名同一个 Stack id，1M 模型四档都带标记

    func test_applyAggregation_fourRoleAliasesShareOneStackIDWithOneMMarkerOnAllTiers() throws {
        try writer.applyAggregation(defaultProfile: zhipu1M, published: [zhipuGLM], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "om-claude-zhipu--glm-5.2[1M]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, "om-claude-zhipu--glm-5.2[1M]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_FABLE_MODEL"] as? String, "om-claude-zhipu--glm-5.2[1M]")
        // Haiku 档同样带标记：Stack id 非 claude- 前缀，缺标记会被按 200K 窗口算（cc-switch 3d46e06c）。
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, "om-claude-zhipu--glm-5.2[1M]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] as? String, "GLM 5.2")
    }

    /// 非 1M 模型默认时四档都不带标记——oneM 跟随发布源，而非恒定值。
    func test_applyAggregation_nonOneMDefaultLeavesAllTiersUnmarked() throws {
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "om-claude-kimi--k3")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, "om-claude-kimi--k3")
    }

    // MARK: - 不写的键

    func test_applyAggregation_doesNotWriteAnthropicModelOrSubagent() throws {
        try writeSettings(["env": ["ANTHROPIC_MODEL": "stale", "CLAUDE_CODE_SUBAGENT_MODEL": "stale-sub"]])
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertNil(env["CLAUDE_CODE_SUBAGENT_MODEL"])
    }

    // MARK: - 代理地址与占位凭证

    func test_applyAggregation_writesBareOriginAndPlaceholderToken() throws {
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:15721")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "PROXY_MANAGED")
    }

    // MARK: - MAX 窗口 = 默认发布模型窗口，200K 不写

    /// 回归：小成员不再拖累默认模型。原先取非 1M 最小值，把 400K 的默认模型
    /// 压到 128K；现在跟随默认发布模型（四档别名共同指向的第一个）。
    func test_applyAggregation_maxContextTokensUsesDefaultModelWindow() throws {
        let wide = makePublished(key: "a", model: "m-a", window: 400_000)
        let narrow = makePublished(key: "b", model: "m-b", window: 128_000)
        try writer.applyAggregation(defaultProfile: kimi, published: [wide, narrow], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertEqual(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String, "400000")
    }

    func test_applyAggregation_maxContextTokensOmittedWhenAllWindowsAreDefault() throws {
        try writer.applyAggregation(defaultProfile: kimi, published: [makePublished(key: "a", model: "m", window: 200_000)], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertNil(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
    }

    func test_applyAggregation_oneMModelsDoNotConstrainMaxWindow() throws {
        let oneM = makePublished(key: "a", model: "m-a", window: 1_000_000, oneM: true)
        try writer.applyAggregation(defaultProfile: kimi, published: [oneM], port: 15721)
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertNil(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
    }

    // MARK: - 只动拥有键

    func test_applyAggregation_preservesUnrelatedSettingsKeys() throws {
        try writeSettings([
            "permissions": ["allow": ["Bash"]],
            "hooks": ["PreToolUse": [["matcher": "Bash"]]],
            "statusLine": ["type": "command"],
            "env": ["SOME_USER_KEY": "keep-me"]
        ])
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let root = try readSettings()
        XCTAssertEqual(root["permissions"] as? [String: [String]], ["allow": ["Bash"]])
        XCTAssertNotNil(root["hooks"])
        XCTAssertNotNil(root["statusLine"])
        XCTAssertEqual((root["env"] as? [String: Any])?["SOME_USER_KEY"] as? String, "keep-me")
    }

    // MARK: - 成员兼容开关合并（AggregationSwitchMerger 的结果在拥有键清理后写入）

    func test_applyAggregation_writesMergedMemberSwitchesAfterOwnedKeyClearing() throws {
        // 直连残留的开关键先被清掉，再由合并结果写入——否则成员自己的开关被静默丢弃。
        try writeSettings([
            "env": [
                "ENABLE_TOOL_SEARCH": "0",
                "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "false",
                "SOME_USER_KEY": "keep-me",
            ]
        ])
        try writer.applyAggregation(
            defaultProfile: kimi, published: [kimiK3], port: 15721,
            memberSwitches: ["ENABLE_TOOL_SEARCH": "1", "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "true"]
        )
        let env = try XCTUnwrap(try readSettings()["env"] as? [String: Any])
        XCTAssertEqual(env["ENABLE_TOOL_SEARCH"] as? String, "1")
        XCTAssertEqual(env["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"] as? String, "true")
        XCTAssertEqual(env["SOME_USER_KEY"] as? String, "keep-me", "非拥有键原样保留")
    }

    func test_applyAggregation_emptyPublishAlsoWritesMemberSwitches() throws {
        // 空发布路径同样写合并键：开关与发布内容正交（SPEC §2 无空发布豁免）。
        try writer.applyAggregation(
            defaultProfile: kimi, published: [], port: 15721,
            memberSwitches: ["CLAUDE_CODE_AUTO_MODE_SERVER": "false"]
        )
        let root = try readSettings()
        XCTAssertEqual((root["env"] as? [String: Any])?["CLAUDE_CODE_AUTO_MODE_SERVER"] as? String, "false")
        XCTAssertNil(root["modelPicker"], "空发布仍不写 modelPicker（Task 1 行为不回归）")
    }

    func test_projectedContractDigest_coversMemberSwitches() {
        // 「未变更不重写」闸门必须看得见开关变化，否则只改开关的投影会被悄悄跳过。
        let before = writer.projectedContractDigest(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let after = writer.projectedContractDigest(
            defaultProfile: kimi, published: [kimiK3], port: 15721,
            memberSwitches: ["ENABLE_TOOL_SEARCH": "1"]
        )
        XCTAssertNotEqual(before, after)
    }

    // MARK: - 退出清理

    func test_clearAggregation_removesModelPickerAndOwnedKeys() throws {
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        try writer.clearAggregation()
        let root = try readSettings()
        XCTAssertNil(root["modelPicker"])
        let env = root["env"] as? [String: Any] ?? [:]
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }

    func test_applyAggregation_replacesUserHandWrittenModelPicker() throws {
        try writeSettings(["modelPicker": ["replaceBuiltInOptions": false, "options": [["model": "mine"]]]])
        try writer.applyAggregation(defaultProfile: kimi, published: [kimiK3], port: 15721)
        let picker = try XCTUnwrap(try readSettings()["modelPicker"] as? [String: Any])
        XCTAssertEqual(picker["replaceBuiltInOptions"] as? Bool, true)
        XCTAssertEqual((picker["options"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - 窗口缩写

    func test_windowLabel_abbreviations() {
        XCTAssertNil(AggregationModelPublisher.windowLabel(0))
        XCTAssertEqual(AggregationModelPublisher.windowLabel(1_000_000), "1M")
        XCTAssertEqual(AggregationModelPublisher.windowLabel(256_000), "256K")
        XCTAssertEqual(AggregationModelPublisher.windowLabel(500), "500")
    }

    // MARK: - 发布源

    func test_published_usesStackModelsThenMappingOrder() {
        XCTAssertEqual(AggregationModelPublisher.published(profile: kimi, key: "kimi").map(\.id),
                       ["om-claude-kimi--k3"])
    }
}
