import XCTest
@testable import OmniForge

/// 路径解析纯函数：CLAUDE_CONFIG_DIR / CODEX_HOME 覆盖与默认值。
final class ProviderSwitchPathsTests: XCTestCase {
    private let homePath = "/Users/tester"

    // MARK: - Claude Code

    func test_claudeSettingsURL_defaultsToHome() {
        XCTAssertEqual(
            ProviderSwitchPaths.claudeSettingsURL(homePath: homePath, environment: [:]).path,
            "/Users/tester/.claude/settings.json"
        )
    }

    func test_claudeSettingsURL_honorsClaudeConfigDir() {
        XCTAssertEqual(
            ProviderSwitchPaths.claudeSettingsURL(
                homePath: homePath,
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"]
            ).path,
            "/tmp/cc/settings.json"
        )
    }

    func test_claudeSettingsURL_ignoresEmptyOverride() {
        XCTAssertEqual(
            ProviderSwitchPaths.claudeSettingsURL(
                homePath: homePath,
                environment: ["CLAUDE_CONFIG_DIR": ""]
            ).path,
            "/Users/tester/.claude/settings.json"
        )
    }

    func test_claudeProfileDirectory_ccqCompatible() {
        XCTAssertEqual(
            ProviderSwitchPaths.claudeProfileDirectory(homePath: homePath, environment: [:]).path,
            "/Users/tester/.claude/providers"
        )
        XCTAssertEqual(
            ProviderSwitchPaths.claudeProfileDirectory(
                homePath: homePath,
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"]
            ).path,
            "/tmp/cc/providers"
        )
    }

    // MARK: - Codex

    func test_codexConfigURL_defaultsToHome() {
        XCTAssertEqual(
            ProviderSwitchPaths.codexConfigURL(homePath: homePath, environment: [:]).path,
            "/Users/tester/.codex/config.toml"
        )
    }

    func test_codexConfigURL_honorsCodexHome() {
        XCTAssertEqual(
            ProviderSwitchPaths.codexConfigURL(
                homePath: homePath,
                environment: ["CODEX_HOME": "/tmp/cx"]
            ).path,
            "/tmp/cx/config.toml"
        )
    }

    func test_codexProfileDirectory_isCodexHome() {
        XCTAssertEqual(
            ProviderSwitchPaths.codexProfileDirectory(homePath: homePath, environment: [:]).path,
            "/Users/tester/.codex"
        )
        XCTAssertEqual(
            ProviderSwitchPaths.codexProfileDirectory(
                homePath: homePath,
                environment: ["CODEX_HOME": "/tmp/cx"]
            ).path,
            "/tmp/cx"
        )
    }

    // MARK: - 统一入口

    func test_configURL_forToolRoutesToCorrectFile() {
        XCTAssertEqual(
            ProviderSwitchPaths.configURL(for: .claudeCode, homePath: homePath, environment: [:]).path,
            "/Users/tester/.claude/settings.json"
        )
        XCTAssertEqual(
            ProviderSwitchPaths.configURL(for: .codex, homePath: homePath, environment: [:]).path,
            "/Users/tester/.codex/config.toml"
        )
    }

    func test_profileDirectory_forToolRoutesCorrectly() {
        XCTAssertEqual(
            ProviderSwitchPaths.profileDirectory(for: .claudeCode, homePath: homePath, environment: [:]).path,
            "/Users/tester/.claude/providers"
        )
        XCTAssertEqual(
            ProviderSwitchPaths.profileDirectory(for: .codex, homePath: homePath, environment: [:]).path,
            "/Users/tester/.codex"
        )
    }

    // MARK: - 备份

    func test_backupDirectory_underApplicationSupport() {
        XCTAssertEqual(
            ProviderSwitchPaths.backupDirectory(
                applicationSupportRoot: URL(fileURLWithPath: "/tmp/AppSupport")
            ).path,
            "/tmp/AppSupport/ProviderSwitchBackups"
        )
    }
}
