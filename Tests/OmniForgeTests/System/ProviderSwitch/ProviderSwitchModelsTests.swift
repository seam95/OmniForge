import XCTest
@testable import OmniForge

/// 领域模型：ProviderTool / ProviderProfile（slug 规则）/ ActiveProvider / 内置 preset 目录。
final class ProviderSwitchModelsTests: XCTestCase {
    // MARK: - ProviderTool

    func test_toolCasesBothCovered() {
        XCTAssertEqual(ProviderTool.allCases, [.claudeCode, .codex])
        XCTAssertEqual(ProviderTool.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(ProviderTool.codex.rawValue, "codex")
    }

    func test_toolConfigFileNames() {
        XCTAssertEqual(ProviderTool.claudeCode.configFileName, "settings.json")
        XCTAssertEqual(ProviderTool.codex.configFileName, "config.toml")
    }

    func test_toolProfileDirectoryNames() {
        XCTAssertEqual(ProviderTool.claudeCode.profileDirectoryName, "providers")
        XCTAssertNil(ProviderTool.codex.profileDirectoryName, "Codex profile 落 home 根")
    }

    func test_claudeOwnedEnvKeys() {
        XCTAssertEqual(
            ProviderTool.claudeOwnedEnvKeys,
            ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"]
        )
    }

    func test_codexOwnedKeys() {
        XCTAssertEqual(
            ProviderTool.codexOwnedTopLevelKeys,
            ["model_provider", "model"]
        )
        XCTAssertEqual(
            ProviderTool.codexOwnedProviderKeys,
            ["name", "base_url", "wire_api", "experimental_bearer_token"]
        )
    }

    // MARK: - ProviderProfile.slugify

    func test_slugify_asciiName() {
        XCTAssertEqual(ProviderProfile.slugify("GLM"), "glm")
        XCTAssertEqual(ProviderProfile.slugify("DeepSeek"), "deepseek")
    }

    func test_slugify_spacesAndPunctuationFoldToDash() {
        XCTAssertEqual(ProviderProfile.slugify("My Provider"), "my-provider")
        XCTAssertEqual(ProviderProfile.slugify("GLM (Zhipu)"), "glm-zhipu")
        XCTAssertEqual(ProviderProfile.slugify("  A  B  "), "a-b")
    }

    func test_slugify_cjkFoldsAndCollapses() {
        XCTAssertEqual(ProviderProfile.slugify("GLM 智谱"), "glm")
        XCTAssertEqual(ProviderProfile.slugify("我的供应商"), "profile", "全 CJK → 回退占位 slug")
    }

    func test_slugify_emptyFallsBack() {
        XCTAssertEqual(ProviderProfile.slugify(""), "profile")
    }

    // MARK: - ProviderProfile

    func test_profileKeyDerivedFromName() {
        let profile = ProviderProfile(
            id: "glm",
            name: "GLM",
            tool: .claudeCode,
            baseURL: "https://example.com",
            token: "sk-x",
            modelOverride: nil,
            smallFastModelOverride: nil,
            managedBy: ProviderProfile.managedByMarker
        )
        XCTAssertEqual(profile.profileKey, "glm")
        XCTAssertTrue(profile.isManagedByOmniForge)
        XCTAssertTrue(profile.hasCompleteConnection)
    }

    func test_profile_foreignFileNotManaged() {
        let profile = ProviderProfile(
            id: "ccq-file",
            name: "CCQ GLM",
            tool: .claudeCode,
            baseURL: "https://example.com",
            token: "",
            modelOverride: nil,
            smallFastModelOverride: nil,
            managedBy: nil
        )
        XCTAssertFalse(profile.isManagedByOmniForge)
        XCTAssertFalse(profile.hasCompleteConnection, "缺凭证不可激活")
    }

    func test_profile_codableRoundTrip() throws {
        let profile = ProviderProfile(
            id: "glm",
            name: "GLM",
            tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-secret",
            modelOverride: "glm-4-7",
            smallFastModelOverride: nil,
            managedBy: ProviderProfile.managedByMarker
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    // MARK: - ActiveProvider

    func test_activeProvider_equalityAndAccessors() {
        XCTAssertEqual(ActiveProvider.official, .official)
        XCTAssertTrue(ActiveProvider.official.isOfficial)
        XCTAssertEqual(ActiveProvider.profile(profileID: "glm").profileID, "glm")
        XCTAssertNil(ActiveProvider.official.profileID)
        XCTAssertNil(ActiveProvider.unmanaged(summary: "x").profileID)
        XCTAssertEqual(
            ActiveProvider.unmanaged(summary: "https://example.com"),
            .unmanaged(summary: "https://example.com")
        )
    }

    // MARK: - 内置 preset 目录

    func test_presetCatalog_hasFourBuiltins() {
        XCTAssertEqual(ProviderPresetCatalog.builtins.count, 4)
        XCTAssertEqual(ProviderPresetCatalog.builtins.map(\.id), ["glm", "kimi", "deepseek", "minimax"])
    }

    func test_presetCatalog_uniqueIDs() {
        let ids = ProviderPresetCatalog.builtins.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func test_presetCatalog_eachVendorHasBothToolConnections() {
        for preset in ProviderPresetCatalog.builtins {
            XCTAssertNotNil(preset.claudeCode, "\(preset.id) 应有 Claude Code 连接")
            XCTAssertNotNil(preset.codex, "\(preset.id) 应有 Codex 连接")
            XCTAssertFalse(preset.claudeCode!.baseURL.isEmpty)
            XCTAssertFalse(preset.claudeCode!.defaultModel.isEmpty)
            XCTAssertFalse(preset.codex!.baseURL.isEmpty)
            XCTAssertFalse(preset.codex!.defaultModel.isEmpty)
        }
    }

    func test_presetCatalog_lookup() {
        XCTAssertEqual(ProviderPresetCatalog.preset(id: "glm"), ProviderPresetCatalog.glm)
        XCTAssertNil(ProviderPresetCatalog.preset(id: "unknown"))
    }
}
