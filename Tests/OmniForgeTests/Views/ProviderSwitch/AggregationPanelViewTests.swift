import XCTest
@testable import OmniForge

/// 聚合面板可测成员：模式分段字符串、默认卡片无移除钮、官方账号不入可选名单、
/// 直连互斥判定、双语言非空；外加二期 UI 面的两个纯函数入口——
/// `ClaudeStackModelsField.normalize`/`fromMapping`（SPEC §4 / P1-5 stackModels 编辑区）与
/// `AggregationPanelView.officialDefaultCodexHint`（SPEC §3 / P0-3 官方默认 Codex 提示），
/// 以及 `ProfileEditorView` 保存路径对三组新字段（stackModels / Codex 显示名平行数组）的承载。
@MainActor
final class AggregationPanelViewTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregationPanelViewTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - fixtures

    private var kimiProfile: ProviderProfile {
        ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
        )
    }

    private var glmProfile: ProviderProfile {
        ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
        )
    }

    private var officialProfile: ProviderProfile {
        ProviderProfile(
            id: "anthropic-official", name: "Anthropic", tool: .claudeCode,
            baseURL: "https://api.anthropic.com", token: "sk-official"
        )
    }

    /// 注入式管理器：按需预置「已在聚合 + 名单」的栈（真实 stack store 走临时文件）。
    /// 每个管理器独立子目录——同一测试里的多个管理器不得共享 stack.json。
    private func makeManager(
        inAggregation: Bool,
        defaultID: String,
        members: [String],
        tool: ProviderTool = .claudeCode,
        profiles: [ProviderProfile]? = nil
    ) -> ProviderAggregationManager {
        let root = tmpDir.appendingPathComponent("m-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stackURL = root.appendingPathComponent("stack.json")
        if inAggregation {
            let keys = Dictionary(uniqueKeysWithValues: members.map { ($0, $0) })
            let toolStack = AggregationStack.ToolStack(enabled: true, members: members, keys: keys)
            try? AggregationStackStore(stackURL: stackURL).save(
                tool == .codex
                    ? AggregationStack(claudeCode: .init(), codex: toolStack)
                    : AggregationStack(claudeCode: toolStack)
            )
        }
        return ProviderAggregationManager(
            profileStore: StubProfileStore(),
            backupStore: StubBackupStore(),
            stackStore: AggregationStackStore(stackURL: stackURL),
            pendingStore: AggregationPendingStore(pendingURL: root.appendingPathComponent("pending.json")),
            loginStashStore: StubLoginStashStore(),
            staleDetector: StubStaleDetector(),
            proxy: StubProxy(),
            claudeWriter: StubClaudeWriter(),
            codexWriter: StubCodexWriter(),
            profiles: profiles ?? [kimiProfile, glmProfile, officialProfile]
        )
    }

    /// 切换管理器：真实 store 全走临时 home（空目录 → 空名单，面板只用它解析名字）。
    private func makeSwitchManager() -> ProviderSwitchManager {
        ProviderSwitchManager.production(
            homePath: tmpDir.path,
            environment: [:],
            applicationSupportRoot: tmpDir
        )
    }

    private func makeView() throws -> AggregationPanelView {
        AggregationPanelView(
            manager: makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi"]),
            switchManager: makeSwitchManager(),
            tool: .claudeCode,
            strings: .zhHans
        )
    }

    // MARK: - tests

    func test_modeSegmentRow_existsAndOffersBothModes() throws {
        let view = try makeView()
        XCTAssertEqual(view.strings.providerModeDirect, "直连")
        XCTAssertEqual(view.strings.providerModeAggregation, "聚合")
    }

    func test_defaultMemberCardHasNoRemoveButton() throws {
        let manager = makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi", "glm"])
        let view = AggregationPanelView(manager: manager, switchManager: makeSwitchManager(), tool: .claudeCode, strings: .zhHans)
        XCTAssertFalse(view.showsRemoveButton(for: "kimi"))
        XCTAssertTrue(view.showsRemoveButton(for: "glm"))
    }

    func test_officialProfileIsNotOfferedForJoining() throws {
        let manager = makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi"])
        let offered = AggregationPanelView(manager: manager, switchManager: makeSwitchManager(), tool: .claudeCode,
                                           strings: .zhHans).joinableProfileIDs(manager: manager)
        XCTAssertFalse(offered.contains("anthropic-official"))
        XCTAssertTrue(offered.contains("glm"))
    }

    // MARK: 直连互斥（SPEC 6.10）：聚合生效时直连「连接」必须禁用，防两个写者互相覆盖
    func test_directActionsAreDisabledWhileToolAggregates() throws {
        let aggregating = makeManager(inAggregation: true, defaultID: "kimi", members: ["kimi"])
        XCTAssertTrue(AggregationPanelView(manager: aggregating, switchManager: makeSwitchManager(),
                                           tool: .claudeCode, strings: .zhHans).directActionsDisabled)
        let exited = makeManager(inAggregation: false, defaultID: "kimi", members: ["kimi"])
        XCTAssertFalse(AggregationPanelView(manager: exited, switchManager: makeSwitchManager(),
                                            tool: .claudeCode, strings: .zhHans).directActionsDisabled)
    }

    func test_localization_presentInBothLanguages() {
        for strings in [Strings.en, Strings.zhHans] {
            XCTAssertFalse(strings.providerModeDirect.isEmpty)
            XCTAssertFalse(strings.providerModeAggregation.isEmpty)
            XCTAssertFalse(strings.providerAggregationStatusLead.isEmpty)
            XCTAssertFalse(strings.providerAggregationEnter.isEmpty)
            XCTAssertFalse(strings.providerAggregationExit.isEmpty)
            XCTAssertFalse(strings.providerAggregationOfficialReason.isEmpty)
            XCTAssertFalse(strings.providerAggregationCacheHint.isEmpty)
            XCTAssertFalse(strings.providerMissStackOff.isEmpty)
            XCTAssertFalse(strings.providerMissUnknown.isEmpty)
            XCTAssertFalse(strings.providerMissRemoved.isEmpty)
            XCTAssertFalse(strings.providerMissDeleted.isEmpty)
            XCTAssertFalse(strings.providerAggregationOfficialDefaultCodexHint.isEmpty)
            XCTAssertFalse(strings.providerStackModelsSectionTitle.isEmpty)
            XCTAssertFalse(strings.providerStackModelsAdd.isEmpty)
            XCTAssertFalse(strings.providerStackModelsDelete.isEmpty)
            XCTAssertFalse(strings.providerStackModelsDisplayNamePlaceholder.isEmpty)
            XCTAssertFalse(strings.providerStackModelsModelPlaceholder.isEmpty)
            XCTAssertFalse(strings.providerStackModelsOneM.isEmpty)
            XCTAssertFalse(strings.providerStackModelsEmptyHint.isEmpty)
            XCTAssertFalse(strings.providerCodexModelDisplayNamePlaceholder.isEmpty)
        }
    }

    // MARK: - stackModels 编辑区（SPEC §4 / P1-5）：normalize / fromMapping 纯函数

    /// 对齐 cc-switch `normalizeClaudeStackModels`（`ClaudeStackModelsField.tsx:38-63`）：
    /// 去空行、模型名字面 `[1m]` 转 oneM、剥标记后同名合并。
    func test_normalize_stripsLiteralOneMAndMergesDuplicates() {
        let out = ClaudeStackModelsField.normalize([
            ClaudeStackModel(model: "k3[1m]", displayName: nil, oneM: false),
            ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false),
            ClaudeStackModel(model: "  ", displayName: nil, oneM: false),
        ])
        XCTAssertEqual(out, [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: true)])
    }

    /// 标记大小写不敏感（`[1M]` 同 `[1m]`）；合并时显示名取第一个非空，
    /// 后行的空白显示名不覆盖已填值；`oneM` 任一为真即真（含复选框未勾但名字带标记）。
    func test_normalize_markerIsCaseInsensitiveAndDisplayNameTakesFirstNonEmpty() {
        let out = ClaudeStackModelsField.normalize([
            ClaudeStackModel(model: "k3[1M]", displayName: nil, oneM: false),
            ClaudeStackModel(model: " k3 ", displayName: "Kimi K3", oneM: false),
            ClaudeStackModel(model: "k3[1m]", displayName: "  ", oneM: true),
        ])
        XCTAssertEqual(out, [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: true)])
    }

    /// 全空（含「只有标记、剥完即空」的行）→ `[]`：用户主动清空必须落成空数组，
    /// 不能回落 nil——否则下次打开又按映射长出推导模型，删除被静默还原。
    func test_normalize_allBlankRowsYieldEmptyList() {
        XCTAssertEqual(ClaudeStackModelsField.normalize([]), [])
        XCTAssertEqual(
            ClaudeStackModelsField.normalize([
                ClaudeStackModel(model: "", displayName: nil, oneM: false),
                ClaudeStackModel(model: "   ", displayName: "x", oneM: true),
                ClaudeStackModel(model: "[1M]", displayName: nil, oneM: false),
            ]),
            []
        )
    }

    /// 首行联动（SPEC §4）：第一行的模型值（normalize 后）就是 `ANTHROPIC_MODEL` 的值，
    /// 1M 行带规范标记；列表为空 → nil（删光了不碰默认模型字段）。
    func test_defaultModel_takesFirstNormalizedRowWithMarker() {
        XCTAssertEqual(
            ClaudeStackModelsField.defaultModel([
                ClaudeStackModel(model: "k3", displayName: nil, oneM: true),
                ClaudeStackModel(model: "k2", displayName: nil, oneM: false),
            ]),
            "k3[1M]"
        )
        XCTAssertEqual(
            ClaudeStackModelsField.defaultModel([ClaudeStackModel(model: "  ", displayName: nil, oneM: false)]),
            nil
        )
        XCTAssertNil(ClaudeStackModelsField.defaultModel([]))
    }

    /// 未配置（`stackModels == nil`）→ 按 `profile.aggregationModels` 推导序回显：
    /// `ANTHROPIC_MODEL` → opus → sonnet → haiku → fable；空档跳过，subagent 不发布。
    func test_fromMapping_fallsBackToAggregationModelsInDerivationOrder() {
        let profile = ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk",
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(
                sonnet: "glm-5.3-air",
                opus: "glm-5.3",
                opusName: "GLM Opus",
                fable: nil,
                haiku: nil,
                subagent: "glm-sub"
            )
        )

        let rows = ClaudeStackModelsField.fromMapping(profile: profile)
        XCTAssertEqual(rows.map(\.model), ["glm-5.3", "glm-5.3", "glm-5.3-air"])
        XCTAssertEqual(rows.map(\.displayName), [nil, "GLM Opus", nil], "显示名随档位取值")
    }

    /// 已配置（含空数组）→ 原样返回：`[]` 是「用户主动清空」，不得被推导值顶掉。
    func test_fromMapping_returnsStoredStackModelsVerbatim() {
        let stored = [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: true)]
        let configured = ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk",
            modelOverride: "ignored",
            stackModels: stored
        )
        XCTAssertEqual(ClaudeStackModelsField.fromMapping(profile: configured), stored)

        let cleared = ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk",
            modelOverride: "ignored",
            stackModels: []
        )
        XCTAssertEqual(ClaudeStackModelsField.fromMapping(profile: cleared), [])
    }

    // MARK: - 官方默认 Codex 提示（SPEC §3 / P0-3 的 UI 面）

    func test_officialDefaultCodexHint_shownOnlyForCodexWithOfficialDefault() throws {
        let official = ProviderProfile(
            id: "openai", name: "OpenAI", tool: .codex,
            baseURL: "https://api.openai.com/v1", token: ""
        )
        let thirdParty = ProviderProfile(
            id: "kimi-codex", name: "Kimi", tool: .codex,
            baseURL: "https://api.kimi.com/v1", token: "sk"
        )

        let codexOfficial = AggregationPanelView(
            manager: makeManager(inAggregation: true, defaultID: "openai", members: ["openai"],
                                 tool: .codex, profiles: [official]),
            switchManager: makeSwitchManager(), tool: .codex, strings: .zhHans
        )
        XCTAssertEqual(
            codexOfficial.officialDefaultCodexHint(manager: codexOfficial.manager),
            Strings.zhHans.providerAggregationOfficialDefaultCodexHint
        )

        let codexThirdParty = AggregationPanelView(
            manager: makeManager(inAggregation: true, defaultID: "kimi-codex", members: ["kimi-codex"],
                                 tool: .codex, profiles: [thirdParty]),
            switchManager: makeSwitchManager(), tool: .codex, strings: .zhHans
        )
        XCTAssertNil(codexThirdParty.officialDefaultCodexHint(manager: codexThirdParty.manager))

        // Claude 侧恒不显示：官方 Anthropic 默认走既有 BASE_URL + token 替换路径（SPEC §3）。
        let claudeOfficial = AggregationPanelView(
            manager: makeManager(inAggregation: true, defaultID: "openai", members: ["openai"],
                                 tool: .claudeCode, profiles: [official]),
            switchManager: makeSwitchManager(), tool: .claudeCode, strings: .zhHans
        )
        XCTAssertNil(claudeOfficial.officialDefaultCodexHint(manager: claudeOfficial.manager))

        // 未进入聚合 → 无默认那家，不显示。
        let exited = AggregationPanelView(
            manager: makeManager(inAggregation: false, defaultID: "openai", members: ["openai"],
                                 tool: .codex, profiles: [official]),
            switchManager: makeSwitchManager(), tool: .codex, strings: .zhHans
        )
        XCTAssertNil(exited.officialDefaultCodexHint(manager: exited.manager))
    }

    // MARK: - 保存路径承载（R1 / R2 / R3）

    /// 保存必须带上 stackModels：normalize 后的行原样进 profile；
    /// 全空 → `[]`（主动清空）而非 nil（未配置）——两者语义相反，不可混淆。
    @MainActor
    func test_save_claudeProfileCarriesNormalizedStackModels() throws {
        let view = makeEditor(tool: .claudeCode, profile: nil)

        let configured = view.makeProfile(
            name: "Kimi", baseURL: "https://api.kimi.com/coding", token: "sk",
            modelOverride: nil, reasoningEffort: nil, codexModels: nil, modelMapping: nil,
            extraEnv: [:],
            stackModels: ClaudeStackModelsField.normalize([
                ClaudeStackModel(model: "k3[1m]", displayName: nil, oneM: false),
                ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false),
                ClaudeStackModel(model: " ", displayName: nil, oneM: false),
            ]),
            codexModelDisplayNames: nil
        )
        XCTAssertEqual(
            configured.stackModels,
            [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: true)]
        )

        let cleared = view.makeProfile(
            name: "Kimi", baseURL: "https://api.kimi.com/coding", token: "sk",
            modelOverride: nil, reasoningEffort: nil, codexModels: nil, modelMapping: nil,
            extraEnv: [:],
            stackModels: ClaudeStackModelsField.normalize([
                ClaudeStackModel(model: "  ", displayName: nil, oneM: false)
            ]),
            codexModelDisplayNames: nil
        )
        XCTAssertNotNil(cleared.stackModels, "主动清空不得回落 nil（未配置）")
        XCTAssertEqual(cleared.stackModels, [])
    }

    /// Codex 显示名平行数组必须与**过滤后**的模型列表同源对齐：空白模型行被丢掉时，
    /// 它的显示名必须一起丢（否则整体串位——数据层容错不崩，只会静默显示错的名字）。
    @MainActor
    func test_save_codexDisplayNamesAlignWithPostFilterModelList() throws {
        let view = makeEditor(tool: .codex, profile: nil)

        let rows = ProfileEditorView.alignedCodexSaveRows(
            models: ["", "  ", "kimi-k3", "kimi-k2"],
            displayNames: ["幽灵名", "x", "Kimi K3", ""]
        )
        XCTAssertEqual(rows.map(\.model), ["kimi-k3", "kimi-k2"])
        XCTAssertEqual(rows.map(\.displayName), ["Kimi K3", ""])

        // 显示名数组比模型短（历史档案长度不齐）→ 越界按未配置补空，不崩不丢模型。
        let short = ProfileEditorView.alignedCodexSaveRows(
            models: ["kimi-k3", "kimi-k2"],
            displayNames: ["Kimi K3"]
        )
        XCTAssertEqual(short.map(\.model), ["kimi-k3", "kimi-k2"])
        XCTAssertEqual(short.map(\.displayName), ["Kimi K3", ""])

        let saved = view.makeProfile(
            name: "Kimi", baseURL: "https://api.kimi.com/v1", token: "sk",
            modelOverride: nil, reasoningEffort: nil,
            codexModels: rows.map(\.model), modelMapping: nil, extraEnv: [:],
            stackModels: nil,
            codexModelDisplayNames: rows.map(\.displayName)
        )
        XCTAssertEqual(saved.modelDisplayNames, ["Kimi K3", ""])

        // 一个都没配 → nil（不写键，保持既有落盘形状）。
        XCTAssertNil(ProfileEditorView.codexDisplayNamesForSave([("kimi-k3", "")]))
        XCTAssertNil(ProfileEditorView.codexDisplayNamesForSave([]))
        XCTAssertEqual(
            ProfileEditorView.codexDisplayNamesForSave([("kimi-k3", "Kimi K3"), ("kimi-k2", "")]),
            ["Kimi K3", ""],
            "有任一个非空就原样写（含空串占位），保住按位对齐"
        )
    }

    /// 编辑器 harness：`makeProfile` 是纯构造（不碰 manager），故切换管理器用生产构造 + 临时 home。
    @MainActor
    private func makeEditor(tool: ProviderTool, profile: ProviderProfile?) -> ProfileEditorView {
        ProfileEditorView(
            manager: ProviderSwitchManager.production(
                homePath: tmpDir.path, environment: [:], applicationSupportRoot: tmpDir
            ),
            strings: .zhHans,
            tool: tool,
            profile: profile
        )
    }
}

// MARK: - Stubs（各测试文件自建）

private final class StubProxy: AggregationProxying {
    var isRunning = false
    var resolvedPort: UInt16?
    var onUnexpectedStop: (() -> Void)?
    func start() throws {
        isRunning = true
        resolvedPort = 15721
    }
    func stop() {
        isRunning = false
        resolvedPort = nil
    }
}

private final class StubProfileStore: ProviderProfileStoring {
    func list(for tool: ProviderTool) -> [ProviderProfile] { [] }
    func upsert(_ profile: ProviderProfile) throws {}
    func delete(_ profile: ProviderProfile) throws {}
    func adopt(name: String, tool: ProviderTool, baseURL: String, token: String, modelOverride: String?) throws -> ProviderProfile {
        ProviderProfile(id: "", name: name, tool: tool, baseURL: baseURL, token: token, modelOverride: modelOverride)
    }
}

private final class StubBackupStore: ProviderBackupStoring {
    private var backups: [ProviderTool: [ProviderBackup]] = [:]
    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
        let backup = ProviderBackup(id: "stub-\(UUID().uuidString)", tool: tool, date: Date())
        backups[tool, default: []].insert(backup, at: 0)
        return backup
    }
    func list(tool: ProviderTool) -> [ProviderBackup] { backups[tool] ?? [] }
    func content(of backup: ProviderBackup) throws -> String { "" }
    func restore(_ backup: ProviderBackup, to configURL: URL) throws {}
}

private final class StubLoginStashStore: CodexLoginStashStoring {
    var hasNativeLogin = false
    func stash() throws -> Bool { false }
    func restore() throws -> Bool { false }
    func discard() throws {}
}

private final class StubStaleDetector: CodexStaleClientDetecting {
    func observe(catalogURL: URL, catalogIsOurs: Bool) {}
    func observeLogin(authURL: URL) {}
    func acknowledge(catalogURL: URL, authURL: URL) {}
    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? { nil }
}

private final class StubClaudeWriter: AggregationClaudeConfigWriting {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) -> String { "" }
}

private final class StubCodexWriter: AggregationCodexConfigWriting {
    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
        defaultIsOfficial: Bool
    ) -> String { "" }
}
