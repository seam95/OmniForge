import XCTest
@testable import OmniForge

/// Claude Desktop 4 文件事务写入：结构（网关字段 / prefer1m 条目随行）、恢复 1P、
/// `_meta.json` 条目保留与 appliedId 切换、entries 非数组报错、首次创建、
/// pending 重放幂等与部分写入补完。
final class ClaudeDesktopSettingsStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var store: ClaudeDesktopSettingsStore!
    private var configURL: URL!
    private var config3PURL: URL!
    private var profileURL: URL!
    private var metaURL: URL!
    private var pendingURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeDesktopSettingsStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // 4 文件模拟真实目录布局（Application Support/Claude 与 Claude-3p/configLibrary）。
        let support = tmpDir.appendingPathComponent("Claude", isDirectory: true)
        let sandbox = tmpDir.appendingPathComponent("Claude-3p/configLibrary", isDirectory: true)
        configURL = support.appendingPathComponent("claude_desktop_config.json")
        config3PURL = tmpDir.appendingPathComponent("Claude-3p/claude_desktop_config.json")
        profileURL = sandbox.appendingPathComponent("\(ClaudeDesktopSettingsStore.profileID).json")
        metaURL = sandbox.appendingPathComponent("_meta.json")
        pendingURL = tmpDir.appendingPathComponent("ProviderDesktop/pending.json")
        store = ClaudeDesktopSettingsStore(
            configURL: configURL,
            config3PURL: config3PURL,
            profileURL: profileURL,
            metaURL: metaURL,
            pendingURL: pendingURL
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    private func makeProfile(routes: [String: DesktopModelRoute]? = nil) -> ProviderProfile {
        ProviderProfile(
            id: "glm", name: "智谱", tool: .claudeDesktop,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-glm", desktopModelRoutes: routes
        )
    }

    // MARK: - applyProfile

    func test_applyProfile_writesFourFileStructureOnFirstCreation() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))

        try store.applyProfile(makeProfile(), inferenceModels: nil, modelDiscoveryEnabled: nil)

        let profile = try readJSONObject(profileURL)
        XCTAssertEqual(profile["inferenceProvider"] as? String, "gateway")
        XCTAssertEqual(profile["inferenceGatewayBaseUrl"] as? String, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(profile["inferenceGatewayApiKey"] as? String, "sk-glm")
        XCTAssertEqual(profile["inferenceGatewayAuthScheme"] as? String, "bearer")
        XCTAssertEqual(profile["coworkEgressAllowedHosts"] as? [String], ["*"])
        XCTAssertEqual(profile["disableDeploymentModeChooser"] as? Bool, true)

        let meta = try readJSONObject(metaURL)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["id"] as? String, ClaudeDesktopSettingsStore.profileID)
        XCTAssertEqual(meta["appliedId"] as? String, ClaudeDesktopSettingsStore.profileID)

        XCTAssertEqual((try readJSONObject(config3PURL))["deploymentMode"] as? String, "3p")
        XCTAssertEqual((try readJSONObject(configURL))["deploymentMode"] as? String, "3p")
        // 事务完成 → pending 已删。
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    }

    func test_applyProfile_writesInferenceModelsWithPrefer1mVerbatim() throws {
        let models: [Any] = [
            "claude-sonnet-5",
            ["name": "k3", "labelOverride": "Kimi K3", "supports1m": true, "prefer1m": true],
        ]
        try store.applyProfile(makeProfile(), inferenceModels: models, modelDiscoveryEnabled: false)
        let profile = try readJSONObject(profileURL)
        XCTAssertEqual(profile["modelDiscoveryEnabled"] as? Bool, false)
        let written = try XCTUnwrap(profile["inferenceModels"] as? [[String: Any]])
        XCTAssertEqual(written[0]["name"] as? String, "k3")
        XCTAssertEqual(written[0]["prefer1m"] as? Bool, true, "prefer1m 必须随 supports1m 一起写入")
    }

    func test_applyProfile_rejectsMappingCardForDirectMode() throws {
        let routes = ["claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false)]
        XCTAssertThrowsError(try store.applyProfile(makeProfile(routes: routes), inferenceModels: nil, modelDiscoveryEnabled: nil)) { error in
            XCTAssertEqual(error as? ClaudeDesktopSettingsError, .modelRoutesRequireAggregation)
        }
    }

    func test_applyProfile_preservesUserKeysInAllFourFiles() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"deploymentMode":"1p","mcpServers":{"fs":{"command":"x"}}}"#.utf8).write(to: configURL)
        try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"inferenceProvider":"old","favoriteColor":"blue"}"#.utf8).write(to: profileURL)
        try Data(#"{"entries":[{"id":"user-own","name":"My Gateway"}],"appliedId":"user-own"}"#.utf8).write(to: metaURL)

        try store.applyProfile(makeProfile(), inferenceModels: nil, modelDiscoveryEnabled: nil)

        // 1P config：只改 deploymentMode，MCP 配置保留。
        let config = try readJSONObject(configURL)
        XCTAssertEqual(config["deploymentMode"] as? String, "3p")
        XCTAssertNotNil(config["mcpServers"])
        // profile：网关字段整体替换（行为定义），用户其它键保留。
        let profile = try readJSONObject(profileURL)
        XCTAssertEqual(profile["favoriteColor"] as? String, "blue")
        // _meta.json：用户条目原样保留 + 我们的条目追加，appliedId 切到我们。
        let meta = try readJSONObject(metaURL)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["id"] as? String, "user-own")
        XCTAssertEqual(meta["appliedId"] as? String, ClaudeDesktopSettingsStore.profileID)
    }

    func test_applyProfile_throwsWhenMetaEntriesNotArray() throws {
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"entries":"broken"}"#.utf8).write(to: metaURL)
        XCTAssertThrowsError(try store.applyProfile(makeProfile(), inferenceModels: nil, modelDiscoveryEnabled: nil)) { error in
            XCTAssertEqual(error as? ClaudeDesktopSettingsError, .metaEntriesNotArray(path: metaURL.path))
        }
    }

    /// 审查回归锁：我方条目**只覆盖 id/name**，既有条目的其它字段（note 等）必须保留
    /// （对齐 cc-switch `claude_desktop_keeps_other_meta_entries_in_place`）。
    func test_applyProfile_preservesOtherFieldsOnOurMetaEntry() throws {
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"entries":[{"id":"\(ClaudeDesktopSettingsStore.profileID)","name":"old","note":"user note"}],"appliedId":"x"}
        """
        try Data(json.utf8).write(to: metaURL)
        try store.applyProfile(makeProfile(), inferenceModels: nil, modelDiscoveryEnabled: nil)
        let meta = try readJSONObject(metaURL)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["note"] as? String, "user note", "既有条目的其它字段不得被整条替换丢掉")
        XCTAssertEqual(entries[0]["name"] as? String, ClaudeDesktopSettingsStore.profileName)
    }

    /// 恢复官方要清 3P config 的 legacy `enterpriseConfig` 网关键（cc-switch 同口径：
    /// 残留会让 1P 仍走旧网关，并把明文 Key 留在磁盘上）。
    func test_restoreOfficial_clearsLegacyEnterpriseGatewayKeys() throws {
        try FileManager.default.createDirectory(
            at: config3PURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let json = """
        {"deploymentMode":"3p","enterpriseConfig":{"inferenceGatewayApiKey":"sk-leak","inferenceProvider":"gateway","keepMe":"yes"}}
        """
        try Data(json.utf8).write(to: config3PURL)
        try store.restoreOfficial()
        let config = try readJSONObject(config3PURL)
        XCTAssertEqual(config["deploymentMode"] as? String, "1p")
        let enterprise = try XCTUnwrap(config["enterpriseConfig"] as? [String: Any])
        XCTAssertNil(enterprise["inferenceGatewayApiKey"], "明文 Key 必须清除")
        XCTAssertNil(enterprise["inferenceProvider"])
        XCTAssertEqual(enterprise["keepMe"] as? String, "yes", "非网关键保留")
    }

    /// 空白配置文件视为空对象（对齐 cc-switch `patch_json::parse`），不判损坏。
    func test_applyProfile_treatsBlankConfigAsEmptyObject() throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("   \n".utf8).write(to: configURL)
        XCTAssertNoThrow(try store.applyProfile(makeProfile(), inferenceModels: nil, modelDiscoveryEnabled: nil))
        XCTAssertEqual((try readJSONObject(configURL))["deploymentMode"] as? String, "3p")
    }

    // MARK: - restoreOfficial

    func test_restoreOfficial_clearsGatewayKeysAndRemovesOwnEntry() throws {
        try store.applyProfile(makeProfile(), inferenceModels: ["claude-sonnet-5"], modelDiscoveryEnabled: false)
        try store.restoreOfficial()

        XCTAssertEqual((try readJSONObject(configURL))["deploymentMode"] as? String, "1p")
        XCTAssertEqual((try readJSONObject(config3PURL))["deploymentMode"] as? String, "1p")
        let profile = try readJSONObject(profileURL)
        for key in ClaudeDesktopSettingsStore.profileGatewayKeys {
            XCTAssertNil(profile[key], "恢复官方必须清除关键字段 \(key)")
        }
        // 文件保留（不删除）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path))
        let meta = try readJSONObject(metaURL)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(meta["appliedId"], "无剩余条目时删除 appliedId 键")
    }

    func test_restoreOfficial_switchesAppliedIdToRemainingEntry() throws {
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"entries":[{"id":"user-own","name":"My Gateway"},{"id":"\#(ClaudeDesktopSettingsStore.profileID)","name":"OmniForge"}],"appliedId":"\#(ClaudeDesktopSettingsStore.profileID)"}"#
                .data(using: .utf8)!
        ).write(to: metaURL)
        try store.restoreOfficial()
        let meta = try readJSONObject(metaURL)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["id"] as? String, "user-own")
        XCTAssertEqual(meta["appliedId"] as? String, "user-own")
    }

    // MARK: - readState

    func test_readState_returnsNilFieldsOnMissingFiles() throws {
        let state = try store.readState()
        XCTAssertNil(state.deploymentMode)
        XCTAssertNil(state.appliedId)
        XCTAssertNil(state.inferenceGatewayBaseUrl)
        XCTAssertFalse(state.isOurProfileApplied)
    }

    func test_readState_reportsAppliedFields() throws {
        try store.applyProfile(makeProfile(), inferenceModels: nil, modelDiscoveryEnabled: nil)
        let state = try store.readState()
        XCTAssertEqual(state.deploymentMode, "3p")
        XCTAssertEqual(state.appliedId, ClaudeDesktopSettingsStore.profileID)
        XCTAssertEqual(state.inferenceGatewayBaseUrl, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(state.inferenceGatewayApiKey, "sk-glm")
        XCTAssertTrue(state.isOurProfileApplied)
    }

    // MARK: - 白名单

    func test_isClaudeSafeModelID_acceptsRolePrefixedNamesOnly() {
        XCTAssertTrue(ClaudeDesktopSettingsStore.isClaudeSafeModelID("claude-sonnet-5"))
        XCTAssertTrue(ClaudeDesktopSettingsStore.isClaudeSafeModelID("claude-fable-5"))
        XCTAssertTrue(ClaudeDesktopSettingsStore.isClaudeSafeModelID("anthropic/claude-opus-4-8"))
        XCTAssertTrue(ClaudeDesktopSettingsStore.isClaudeSafeModelID("claude-fable-om-136067"))
        XCTAssertFalse(ClaudeDesktopSettingsStore.isClaudeSafeModelID("glm-5.3"))
        XCTAssertFalse(ClaudeDesktopSettingsStore.isClaudeSafeModelID("k3"))
        XCTAssertFalse(ClaudeDesktopSettingsStore.isClaudeSafeModelID("claude-3-5-sonnet"))
    }

    /// 审查回归锁：对齐 cc-switch 的 trim + 小写 + 拒 [1m] 口径。
    func test_isClaudeSafeModelID_normalizesCaseWhitespaceAndRejectsOneMMarker() {
        XCTAssertTrue(ClaudeDesktopSettingsStore.isClaudeSafeModelID("  CLAUDE-SONNET-5  "))
        XCTAssertFalse(ClaudeDesktopSettingsStore.isClaudeSafeModelID("claude-sonnet-5[1m]"))
        XCTAssertFalse(ClaudeDesktopSettingsStore.isClaudeSafeModelID("claude-sonnet-"))
    }

    func test_defaultRoutesAreClaudeSafe() {
        for route in ClaudeDesktopSettingsStore.defaultRoutes {
            XCTAssertTrue(ClaudeDesktopSettingsStore.isClaudeSafeModelID(route), "默认档 \(route) 必须 Claude-safe")
        }
    }
}
