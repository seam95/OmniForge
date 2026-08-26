import XCTest
@testable import OmniForge

/// CCQ 兼容启动命令的公开行为测试。
final class ProviderLaunchCommandTests: XCTestCase {
    private let homePath = "/Users/tester"

    func test_claudeCode_usesActualProfileIDInSettingsPath() {
        let profile = makeProfile(
            id: "custom-file",
            name: "显示名称",
            tool: .claudeCode
        )

        XCTAssertEqual(
            ProviderLaunchCommand.make(
                for: profile,
                homePath: homePath,
                environment: [:]
            ),
            "claude --settings ~/.claude/providers/custom-file.json"
        )
    }

    func test_claudeCode_honorsClaudeConfigDirectoryOverride() {
        let profile = makeProfile(
            id: "deepseek",
            name: "DeepSeek",
            tool: .claudeCode
        )

        XCTAssertEqual(
            ProviderLaunchCommand.make(
                for: profile,
                homePath: homePath,
                environment: ["CLAUDE_CONFIG_DIR": "/Volumes/AI Config"]
            ),
            "claude --settings '/Volumes/AI Config/providers/deepseek.json'"
        )
    }

    func test_codex_usesActualProfileIDAsProfileArgument() {
        let profile = makeProfile(
            id: "kimi-file",
            name: "Kimi 月之暗面",
            tool: .codex
        )

        XCTAssertEqual(
            ProviderLaunchCommand.make(
                for: profile,
                homePath: homePath,
                environment: [:]
            ),
            "codex --profile kimi-file"
        )
    }

    func test_codex_keepsProfileCommandWhenCodexHomeIsOverridden() {
        let profile = makeProfile(
            id: "custom profile",
            name: "自定义",
            tool: .codex
        )

        XCTAssertEqual(
            ProviderLaunchCommand.make(
                for: profile,
                homePath: homePath,
                environment: ["CODEX_HOME": "/Volumes/Codex Config"]
            ),
            "codex --profile 'custom profile'"
        )
    }

    func test_command_shellEscapesApostrophesInProfileKey() {
        let profile = makeProfile(
            id: "vendor'profile",
            name: "供应商",
            tool: .codex
        )

        XCTAssertEqual(
            ProviderLaunchCommand.make(
                for: profile,
                homePath: homePath,
                environment: [:]
            ),
            "codex --profile 'vendor'\\''profile'"
        )
    }

    private func makeProfile(
        id: String,
        name: String,
        tool: ProviderTool
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            tool: tool,
            baseURL: "https://example.com",
            token: "sk-test",
            modelOverride: nil,
            modelMapping: nil,
            extraEnv: [:],
            managedBy: ProviderProfile.managedByMarker
        )
    }
}
