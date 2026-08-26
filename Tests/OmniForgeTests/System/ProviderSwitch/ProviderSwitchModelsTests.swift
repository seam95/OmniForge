import XCTest
@testable import OmniForge

/// 领域模型：ProviderTool / ProviderProfile（slug 规则）/ ProviderModelMapping / ActiveProvider / 内置 preset 目录。
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
            [
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "ANTHROPIC_MODEL",
                "ANTHROPIC_SMALL_FAST_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
                "ANTHROPIC_DEFAULT_OPUS_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
                "ANTHROPIC_DEFAULT_FABLE_MODEL",
                "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
                "CLAUDE_CODE_SUBAGENT_MODEL",
            ]
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
            modelMapping: nil,
            extraEnv: [:],
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
            modelMapping: nil,
            extraEnv: [:],
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
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(
                sonnet: "glm-5.3",
                sonnetName: "GLM 5.3",
                opus: nil,
                opusName: nil,
                fable: nil,
                fableName: nil,
                haiku: "glm-5-flash",
                haikuName: nil,
                subagent: "glm-5.3"
            ),
            extraEnv: ["CLAUDE_CODE_EFFORT_LEVEL": "max"],
            managedBy: ProviderProfile.managedByMarker
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    // MARK: - ProviderModelMapping

    func test_modelMapping_envEntriesMapsRolesToEnvKeys() {
        let mapping = ProviderModelMapping(
            sonnet: "s",
            sonnetName: "Sonnet",
            opus: "o",
            opusName: "Opus",
            fable: "f",
            fableName: "Fable",
            haiku: "h",
            haikuName: "Haiku",
            subagent: "sub"
        )
        XCTAssertEqual(mapping.nonEmptyEntries.count, 9)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: mapping.nonEmptyEntries),
            [
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "s",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Sonnet",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "o",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Opus",
                "ANTHROPIC_DEFAULT_FABLE_MODEL": "f",
                "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "Fable",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "h",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "Haiku",
                "CLAUDE_CODE_SUBAGENT_MODEL": "sub",
            ]
        )
    }

    func test_modelMapping_isEmptyWhenAllNil() {
        XCTAssertTrue(ProviderModelMapping().isEmpty)
        let mapping = ProviderModelMapping(
            sonnet: nil, sonnetName: nil, opus: nil, opusName: nil,
            fable: nil, fableName: nil, haiku: "h", haikuName: nil, subagent: nil
        )
        XCTAssertFalse(mapping.isEmpty)
    }

    func test_modelMapping_fromEnvSkipsEmptyValues() {
        let mapping = ProviderModelMapping.fromEnv([
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
            "UNRELATED": "x",
        ])
        XCTAssertEqual(mapping.haiku, "deepseek-v4-flash")
        XCTAssertNil(mapping.haikuName, "空值置 nil")
        XCTAssertEqual(mapping.opus, "deepseek-v4-pro")
        XCTAssertNil(mapping.sonnet)
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

    func test_presetCatalog_eachVendorHasClaudeConnection() {
        for preset in ProviderPresetCatalog.builtins {
            XCTAssertNotNil(preset.claudeCode, "\(preset.id) 应有 Claude Code 连接")
            XCTAssertFalse(preset.claudeCode!.baseURL.isEmpty)
            XCTAssertFalse(preset.claudeCode!.defaultModel.isEmpty)
        }
    }

    func test_presetCatalog_onlyKimiLacksCodexConnection() {
        for preset in ProviderPresetCatalog.builtins {
            if preset.id == "kimi" {
                XCTAssertNil(preset.codex, "Kimi 不再提供 Codex preset")
            } else {
                XCTAssertNotNil(preset.codex, "\(preset.id) 应有 Codex 连接")
                XCTAssertFalse(preset.codex!.baseURL.isEmpty)
                XCTAssertFalse(preset.codex!.defaultModel.isEmpty)
            }
        }
    }

    func test_presetCatalog_lookup() {
        XCTAssertEqual(ProviderPresetCatalog.preset(id: "glm"), ProviderPresetCatalog.glm)
        XCTAssertNil(ProviderPresetCatalog.preset(id: "unknown"))
    }

    // MARK: - preset 数据（对齐 ccswitch 契约）

    func test_preset_glm() {
        XCTAssertEqual(ProviderPresetCatalog.glm.claudeCode?.baseURL, "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(ProviderPresetCatalog.glm.codex?.baseURL, "https://open.bigmodel.cn/api/v1")
        XCTAssertEqual(ProviderPresetCatalog.glm.claudeCode?.defaultModel, "glm-5.3")
        XCTAssertEqual(ProviderPresetCatalog.glm.codex?.defaultModel, "glm-5.3")
    }

    func test_preset_minimax() {
        XCTAssertEqual(ProviderPresetCatalog.miniMax.claudeCode?.baseURL, "https://api.minimaxi.com/anthropic")
        XCTAssertEqual(ProviderPresetCatalog.miniMax.codex?.baseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(ProviderPresetCatalog.miniMax.claudeCode?.defaultModel, "MiniMax-M3")
        XCTAssertEqual(ProviderPresetCatalog.miniMax.codex?.defaultModel, "MiniMax-M3")
    }

    func test_preset_deepseek() {
        XCTAssertEqual(ProviderPresetCatalog.deepSeek.claudeCode?.baseURL, "https://api.deepseek.com/anthropic")
        XCTAssertEqual(ProviderPresetCatalog.deepSeek.codex?.baseURL, "https://api.deepseek.com/")
        XCTAssertEqual(ProviderPresetCatalog.deepSeek.claudeCode?.defaultModel, "deepseek-v4-pro")
        XCTAssertEqual(ProviderPresetCatalog.deepSeek.claudeCode?.modelMapping?.haiku, "deepseek-v4-flash")
        XCTAssertEqual(
            ProviderPresetCatalog.deepSeek.claudeCode?.extraEnv,
            ["CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"]
        )
    }

    func test_preset_kimi() {
        XCTAssertEqual(ProviderPresetCatalog.kimi.claudeCode?.baseURL, "https://api.kimi.com/coding")
        XCTAssertEqual(ProviderPresetCatalog.kimi.claudeCode?.defaultModel, "k3[1m]")
        XCTAssertEqual(
            ProviderPresetCatalog.kimi.claudeCode?.extraEnv,
            ["CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1048576", "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1048576"]
        )
        XCTAssertNil(ProviderPresetCatalog.kimi.codex)
    }

    func test_presetCatalog_noKimi256K() {
        XCTAssertFalse(ProviderPresetCatalog.builtins.contains { $0.id.contains("256k") || $0.displayName.contains("256K") })
    }
}
