import XCTest
@testable import OmniForge

/// Claude `settings.json` 字段所有权合并：只动拥有键、切 Official 删 override、损坏中止、原子写。
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
        model: String? = "glm-4-7",
        small: String? = nil
    ) -> ProviderProfile {
        ProviderProfile(
            id: "glm",
            name: name,
            tool: .claudeCode,
            baseURL: baseURL,
            token: token,
            modelOverride: model,
            smallFastModelOverride: small,
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
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "glm-4-7")
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
        // 带模型覆盖
        try makeStore().applyProfile(makeProfile(model: "glm-4-7", small: "glm-4-flash"))
        var env = try XCTUnwrap((try readSettings())["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "glm-4-7")
        XCTAssertEqual(env["ANTHROPIC_SMALL_FAST_MODEL"] as? String, "glm-4-flash")

        // 无覆盖 → 删除旧模型键
        try makeStore().applyProfile(makeProfile(model: nil, small: nil))
        env = try XCTUnwrap((try readSettings())["env"] as? [String: Any])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertNil(env["ANTHROPIC_SMALL_FAST_MODEL"])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-glm", "凭证键仍在")
    }

    // MARK: - 切 Official

    func test_clearOverrides_removesOwnedKeysKeepsOthers() throws {
        try writeSettings([
            "env": [
                "ANTHROPIC_AUTH_TOKEN": "sk-x",
                "ANTHROPIC_BASE_URL": "https://x.example",
                "ANTHROPIC_MODEL": "glm-4-7",
                "CLAUDE_CODE_ENABLE_TELEMETRY": "false",
            ],
            "permissions": ["allow": ["Bash"]],
        ])
        try makeStore().clearOverrides()
        let root = try readSettings()
        XCTAssertEqual(root["permissions"] as? [String: [String]], ["allow": ["Bash"]])
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertNil(env["ANTHROPIC_SMALL_FAST_MODEL"])
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
