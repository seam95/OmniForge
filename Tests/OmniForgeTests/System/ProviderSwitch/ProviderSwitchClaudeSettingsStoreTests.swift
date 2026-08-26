import XCTest
@testable import OmniForge

/// Claude `settings.json` 字段所有权合并：只动拥有键、角色模型映射仅写非空字段、
/// 切 Official 删 override（含新旧映射键）、损坏中止、原子写。
final class ProviderSwitchClaudeSettingsStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSettingsStoreTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        settingsURL = tmpDir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore() -> ClaudeSettingsStore {
        ClaudeSettingsStore(settingsURL: settingsURL)
    }

    private func writeSettings(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeProfile(
        name: String = "GLM",
        baseURL: String = "https://open.bigmodel.cn/api/anthropic",
        token: String = "sk-glm",
        model: String? = "glm-5.3",
        mapping: ProviderModelMapping? = nil,
        extraEnv: [String: String] = [:]
    ) -> ProviderProfile {
        ProviderProfile(
            id: "glm",
            name: name,
            tool: .claudeCode,
            baseURL: baseURL,
            token: token,
            modelOverride: model,
            modelMapping: mapping,
            extraEnv: extraEnv,
            managedBy: ProviderProfile.managedByMarker
        )
    }

    // MARK: - 合并只动拥有键

    func test_applyProfile_createsMinimalFileWhenMissing() throws {
        try makeStore().applyProfile(makeProfile())
        let root = try readSettings()
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-glm")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "glm-5.3")
        XCTAssertNil(env["ANTHROPIC_SMALL_FAST_MODEL"])
        XCTAssertEqual(root.keys.count, 1, "最小文件只含 env")
    }

    func test_applyProfile_preservesUnrelatedKeys() throws {
        try writeSettings([
            "env": ["ANTHROPIC_BASE_URL": "https://old.example", "CLAUDE_CODE_ENABLE_TELEMETRY": "false"],
            "permissions": ["allow": ["Bash"]],
            "hooks": ["Stop": []],
            "statusLine": ["type": "command"],
            "apiKeyHelper": "npx -y @anthropic-ai/claude-code-proxy@latest",
        ])
        try makeStore().applyProfile(makeProfile())
        let root = try readSettings()
        XCTAssertEqual(root["permissions"] as? [String: [String]], ["allow": ["Bash"]])
        XCTAssertEqual(root["hooks"] as? [String: [String]], ["Stop": [String]()])
        XCTAssertEqual(root["statusLine"] as? [String: String], ["type": "command"])
        XCTAssertEqual(root["apiKeyHelper"] as? String, "npx -y @anthropic-ai/claude-code-proxy@latest")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_TELEMETRY"] as? String, "false", "env 非拥有键保留")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-glm")
    }

    func test_applyProfile_modelKeysWrittenOnlyWhenSpecified() throws {
        // 带默认模型 + 角色映射
        try makeStore().applyProfile(makeProfile(
            model: "glm-5.3",
            mapping: ProviderModelMapping(
                sonnet: "glm-5.3",
                sonnetName: "GLM 5.3",
                opus: nil,
                opusName: nil,
                fable: nil,
                fableName: nil,
                haiku: "glm-5-flash",
                haikuName: nil,
                subagent: "glm-5.3"
            )
        ))
        var env = try XCTUnwrap((try readSettings())["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "glm-5.3")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "glm-5.3")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] as? String, "GLM 5.3")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String, "glm-5-flash")
        XCTAssertEqual(env["CLAUDE_CODE_SUBAGENT_MODEL"] as? String, "glm-5.3")
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "空映射字段不写")
        XCTAssertNil(env["ANTHROPIC_SMALL_FAST_MODEL"])

        // 无覆盖 → 删除旧模型键与映射键
        try makeStore().applyProfile(makeProfile(model: nil, mapping: nil))
        env = try XCTUnwrap((try readSettings())["env"] as? [String: Any])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        XCTAssertNil(env["CLAUDE_CODE_SUBAGENT_MODEL"])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-glm", "凭证键仍在")
    }

    func test_applyProfile_writesExtraEnv() throws {
        try makeStore().applyProfile(makeProfile(
            model: "deepseek-v4-pro",
            mapping: ProviderModelMapping(
                sonnet: nil, sonnetName: nil, opus: nil, opusName: nil,
                fable: nil, fableName: nil, haiku: "deepseek-v4-flash", haikuName: nil, subagent: nil
            ),
            extraEnv: ["CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"]
        ))
        let env = try XCTUnwrap((try readSettings())["env"] as? [String: Any])
        XCTAssertEqual(env["CLAUDE_CODE_EFFORT_LEVEL"] as? String, "max")
        XCTAssertEqual(env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String, "786432")
    }

    func test_applyProfile_removesLegacySmallFastModelKey() throws {
        try writeSettings([
            "env": ["ANTHROPIC_SMALL_FAST_MODEL": "glm-4-flash"],
        ])
        try makeStore().applyProfile(makeProfile(model: "glm-5.3", mapping: nil))
        let env = try XCTUnwrap((try readSettings())["env"] as? [String: Any])
        XCTAssertNil(env["ANTHROPIC_SMALL_FAST_MODEL"], "旧小模型键写入时一律移除")
    }

    // MARK: - 切 Official

    func test_clearOverrides_removesOwnedKeysKeepsOthers() throws {
        try writeSettings([
            "env": [
                "ANTHROPIC_AUTH_TOKEN": "sk-x",
                "ANTHROPIC_BASE_URL": "https://x.example",
                "ANTHROPIC_MODEL": "glm-5.3",
                "ANTHROPIC_SMALL_FAST_MODEL": "glm-4-flash",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.3",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "GLM 5.3",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.3",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "GLM 5.3",
                "ANTHROPIC_DEFAULT_FABLE_MODEL": "glm-5.3",
                "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "GLM 5.3",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5-flash",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "GLM 5 Flash",
                "CLAUDE_CODE_SUBAGENT_MODEL": "glm-5.3",
                "CLAUDE_CODE_ENABLE_TELEMETRY": "false",
            ],
            "permissions": ["allow": ["Bash"]],
        ])
        try makeStore().clearOverrides()
        let root = try readSettings()
        XCTAssertEqual(root["permissions"] as? [String: [String]], ["allow": ["Bash"]])
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        for key in ProviderTool.claudeOwnedEnvKeys {
            XCTAssertNil(env[key], "拥有键 \(key) 应被清理")
        }
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_TELEMETRY"] as? String, "false")
    }

    func test_clearOverrides_removesEmptyEnv() throws {
        try writeSettings([
            "env": ["ANTHROPIC_BASE_URL": "https://x.example"],
            "permissions": ["allow": ["Bash"]],
        ])
        try makeStore().clearOverrides()
        let root = try readSettings()
        XCTAssertNil(root["env"], "env 清空后整体移除")
        XCTAssertEqual(root["permissions"] as? [String: [String]], ["allow": ["Bash"]])
    }

    func test_clearOverrides_missingFileIsNoop() throws {
        XCTAssertNoThrow(try makeStore().clearOverrides())
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    // MARK: - 健壮性

    func test_readEnv_missingFileReturnsEmpty() throws {
        XCTAssertEqual(try makeStore().readEnv(), [:])
    }

    func test_corruptedJson_abortsWithoutWrite() throws {
        try Data("{\"env\": broken".utf8).write(to: settingsURL)
        let store = makeStore()
        XCTAssertThrowsError(try store.applyProfile(makeProfile())) { error in
            XCTAssertEqual(error as? ProviderConfigFileError, .corrupted(path: settingsURL.path))
        }
        XCTAssertThrowsError(try store.readEnv())
        // 文件未被改写
        let content = try String(contentsOf: settingsURL)
        XCTAssertEqual(content, "{\"env\": broken")
    }

    func test_applyProfile_writesWith0600Permissions() throws {
        try makeStore().applyProfile(makeProfile())
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }
}
