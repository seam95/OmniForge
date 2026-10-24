import XCTest
@testable import OmniForge

/// 退出聚合的键级恢复：只回滚聚合拥有的键，保留用户在聚合期间改的其他段落。
final class AggregationRestoreMergerTests: XCTestCase {
    private let aggregateConfig = """
    model_provider = "custom"
    model = "aggregate-model"
    model_reasoning_effort = "high"
    model_catalog_json = "omniforge-stack-catalog.json"
    model_context_window = 272000
    model_auto_compact_token_limit = 244800

    [mcp_servers.context7]
    command = "npx"

    [model_providers.custom]
    name = "custom"
    base_url = "http://127.0.0.1:15722/v1"
    wire_api = "responses"
    requires_openai_auth = true
    experimental_bearer_token = "PROXY_MANAGED"
    """

    func test_codex_restoresOwnedKeysAndKeepsUserSections() throws {
        let backup = """
        model = "user-model"
        model_reasoning_effort = "medium"

        [mcp_servers.old]
        command = "old"
        """
        let merged = try XCTUnwrap(AggregationRestoreMerger.codex(
            currentText: aggregateConfig, backupText: backup
        ))
        let doc = try XCTUnwrap(TOMLFile.parse(merged))

        XCTAssertEqual(doc.stringValue(key: "model", table: nil), "user-model")
        XCTAssertEqual(doc.stringValue(key: "model_reasoning_effort", table: nil), "medium")
        XCTAssertNil(doc.stringValue(key: "model_provider", table: nil), "聚合指针被摘除")
        XCTAssertNil(doc.stringValue(key: "model_catalog_json", table: nil))
        XCTAssertNil(doc.stringValue(key: "model_context_window", table: nil))
        XCTAssertNil(doc.stringValue(key: "model_auto_compact_token_limit", table: nil))
        XCTAssertEqual(
            doc.stringValue(key: "command", table: ["mcp_servers", "context7"]), "npx",
            "聚合期间用户新增的段落保留"
        )
        XCTAssertNil(
            doc.stringValue(key: "base_url", table: ["model_providers", "custom"]),
            "进入前没有 custom 表 → 删除聚合指向代理的表"
        )
    }

    func test_codex_restoresUserCustomTableWhenBackupHadOne() throws {
        let backup = """
        model = "user-model"

        [model_providers.custom]
        name = "my-relay"
        base_url = "https://relay.example.com/v1"
        wire_api = "responses"
        """
        let merged = try XCTUnwrap(AggregationRestoreMerger.codex(
            currentText: aggregateConfig, backupText: backup
        ))
        let doc = try XCTUnwrap(TOMLFile.parse(merged))

        XCTAssertEqual(
            doc.stringValue(key: "base_url", table: ["model_providers", "custom"]),
            "https://relay.example.com/v1"
        )
        XCTAssertEqual(
            doc.stringValue(key: "name", table: ["model_providers", "custom"]), "my-relay"
        )
        XCTAssertNil(
            doc.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]),
            "聚合写入的布尔键不残留"
        )
    }

    func test_codex_emptyBackupIsRejected() {
        XCTAssertNil(
            AggregationRestoreMerger.codex(currentText: aggregateConfig, backupText: "  \n"),
            "空快照不能当成合法空文档，否则会静默删掉用户配置"
        )
    }

    func test_codex_restoresNestedCustomTables() throws {
        let backup = """
        model = "user-model"

        [model_providers.custom]
        name = "my-relay"
        base_url = "https://relay.example.com/v1"

        [model_providers.custom.http_headers]
        X-User = "me"
        """
        let merged = try XCTUnwrap(AggregationRestoreMerger.codex(
            currentText: aggregateConfig, backupText: backup
        ))
        let doc = try XCTUnwrap(TOMLFile.parse(merged))
        XCTAssertEqual(
            doc.stringValue(key: "X-User", table: ["model_providers", "custom", "http_headers"]),
            "me"
        )
    }

    func test_codex_keepsUserOwnedCustomTableWhenBackupHadNone() throws {
        let current = """
        model = "aggregate-model"

        [model_providers.custom]
        name = "user-owned"
        base_url = "https://relay.example.com/v1"
        """
        let merged = try XCTUnwrap(AggregationRestoreMerger.codex(
            currentText: current, backupText: "model = \"user-model\"\n"
        ))
        let doc = try XCTUnwrap(TOMLFile.parse(merged))
        XCTAssertEqual(
            doc.stringValue(key: "base_url", table: ["model_providers", "custom"]),
            "https://relay.example.com/v1",
            "不是指向本机代理的 custom 表不得误删"
        )
    }

    func test_claude_restoresOwnedEnvAndModelPickerOnly() throws {
        let current: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:15722",
                "ANTHROPIC_AUTH_TOKEN": "PROXY_MANAGED",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "272000",
                "SOME_USER_KEY": "current",
            ],
            "modelPicker": ["replaceBuiltInOptions": true, "options": []],
            "permissions": ["allow": ["Bash"]],
        ]
        let backup: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                "SOME_USER_KEY": "old",
            ],
            "modelPicker": ["replaceBuiltInOptions": false],
        ]
        let merged = AggregationRestoreMerger.claude(current: current, backup: backup)
        let env = try XCTUnwrap(merged["env"] as? [String: Any])

        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "https://api.anthropic.com")
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"], "聚合占位凭证被摘除")
        XCTAssertNil(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "聚合窗口键被摘除")
        XCTAssertEqual(env["SOME_USER_KEY"] as? String, "current", "非拥有键保留当前值")
        XCTAssertEqual(
            (merged["modelPicker"] as? [String: Any])?["replaceBuiltInOptions"] as? Bool,
            false
        )
        XCTAssertNotNil(merged["permissions"], "非拥有顶层键保留")
    }

}

// MARK: - Claude Desktop

extension AggregationRestoreMergerTests {
    func test_desktop_restoresGatewayKeysFromBackupAndDropsMissingOnes() {
        let current: [String: Any] = [
            "inferenceProvider": "gateway",
            "inferenceGatewayBaseUrl": "http://127.0.0.1:15721/claude-desktop",
            "inferenceGatewayApiKey": "ccs-aggregation",
            "inferenceModels": ["claude-sonnet-5"],
            "favoriteColor": "blue",
        ]
        let backup: [String: Any] = [
            "inferenceProvider": "gateway",
            "inferenceGatewayBaseUrl": "https://open.bigmodel.cn/api/anthropic",
            "inferenceGatewayApiKey": "sk-glm",
            "favoriteColor": "red",
        ]
        let merged = AggregationRestoreMerger.desktop(current: current, backup: backup)
        XCTAssertEqual(merged["inferenceGatewayBaseUrl"] as? String, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(merged["inferenceGatewayApiKey"] as? String, "sk-glm")
        XCTAssertNil(merged["inferenceModels"], "备份缺失的网关键删除（聚合残留清除）")
        XCTAssertNil(merged["modelDiscoveryEnabled"])
        XCTAssertEqual(merged["favoriteColor"] as? String, "blue", "用户其它键保留当前值（不回滚用户改动）")
    }

    func test_desktop_emptyBackupRemovesAllGatewayKeys() {
        let current: [String: Any] = [
            "inferenceProvider": "gateway",
            "inferenceGatewayBaseUrl": "http://127.0.0.1:1/claude-desktop",
            "customKey": 1,
        ]
        let merged = AggregationRestoreMerger.desktop(current: current, backup: [:])
        XCTAssertNil(merged["inferenceProvider"])
        XCTAssertNil(merged["inferenceGatewayBaseUrl"])
        XCTAssertEqual(merged["customKey"] as? Int, 1)
    }
}
