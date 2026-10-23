import XCTest
@testable import OmniForge

/// 聚合面板可测成员：模式分段字符串、默认卡片无移除钮、官方账号不入可选名单、
/// 直连互斥判定、双语言非空；外加二期 UI 面的两个纯函数入口——
/// `ClaudeStackModelsField.normalize`/`fromMapping`（SPEC §4 / P1-5 stackModels 编辑区），
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

    /// 模式两行的标题复用既有 `providerMode*` 键（原「直连/聚合」分段行的文案）。
    func test_modeRowTitles_reuseExistingModeStrings() throws {
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

    /// 直连映射行复选的写入口径（cc-switch `setClaudeOneMMarker` 对齐）：
    /// 勾 = 补无空格标记、去勾 = 剥标记；空值 → 空串（值空了 1M 无从谈起）。
    func test_setOneMMarker_writesAndStripsLiteralMarker() {
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("k3", true), "k3[1M]")
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("k3[1M]", true), "k3[1M]", "已带标记幂等")
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("k3 [1m]", true), "k3[1M]", "大小写与空格形态都收敛到规范标记")
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("k3[1M]", false), "k3")
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("k3", false), "k3")
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("", true), "", "空基础名不产出孤悬标记")
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("  [1M] ", false), "")
        // 勾选态下输入新模型名（oneMAwareTextBinding 的 set 路径）：1M 声明跟随保留。
        XCTAssertEqual(ClaudeStackModelsField.setOneMMarker("glm-6", true), "glm-6[1M]")
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

    /// 单树 Host 下 @State 跨工具残留：Claude 退出的默认不得成为 Codex 的候选。
    func test_undoDefaultID_rejectsCrossToolResidue() {
        let claudeUndo: (tool: ProviderTool, id: String) = (.claudeCode, "deepseek")
        XCTAssertNil(AggregationPanelView.undoDefaultID(claudeUndo, matching: .codex),
                      "跨工具残留（Claude 的 deepseek）不得成为 Codex 的进入候选")
        XCTAssertEqual(AggregationPanelView.undoDefaultID(claudeUndo, matching: .claudeCode), "deepseek")
        XCTAssertNil(AggregationPanelView.undoDefaultID(nil, matching: .codex))
    }

    /// 官方入口卡显示条件：聚合中 + 官方卡存在 + 不在名单。
    func test_showsOfficialEntry_onlyWhenAggregatingAndNotMember() {
        let official = ProviderProfile(
            id: "official-codex", name: "OpenAI", tool: .codex,
            baseURL: "https://api.openai.com/v1", token: ""
        )
        XCTAssertNotNil(AggregationPanelView.showsOfficialEntry(
            isAggregating: true, official: official, isMember: { _ in false }))
        XCTAssertNil(AggregationPanelView.showsOfficialEntry(
            isAggregating: false, official: official, isMember: { _ in false }), "未聚合不显示")
        XCTAssertNil(AggregationPanelView.showsOfficialEntry(
            isAggregating: true, official: official, isMember: { id in id == "official-codex" }),
            "官方已在名单（默认位）不显示")
        XCTAssertNil(AggregationPanelView.showsOfficialEntry(
            isAggregating: true, official: nil, isMember: { _ in false }), "无官方卡不显示")
    }

    /// 官方回落规则（方案 B）：激活官方态 → 官方卡；激活第三方 → 第三方；
    /// 未托管等其余态 → 先第三方首张、无卡再官方兜底。
    func test_resolveDefaultCandidate_fallsBackToOfficialForOfficialActiveState() {
        XCTAssertEqual(
            AggregationPanelView.resolveDefaultCandidate(
                active: .official, profileIDs: ["deepseek"], officialProfileID: "official-codex"),
            "official-codex", "激活官方态 → 官方做默认候选"
        )
        XCTAssertEqual(
            AggregationPanelView.resolveDefaultCandidate(
                active: .profile(profileID: "deepseek"), profileIDs: ["deepseek"], officialProfileID: "official-codex"),
            "deepseek", "激活第三方 → 第三方优先（现状不变）"
        )
        XCTAssertEqual(
            AggregationPanelView.resolveDefaultCandidate(
                active: .unmanaged(summary: "x"), profileIDs: ["deepseek"], officialProfileID: "official-codex"),
            "deepseek", "未托管态 → 有第三方卡用首张"
        )
        XCTAssertEqual(
            AggregationPanelView.resolveDefaultCandidate(
                active: .official, profileIDs: [], officialProfileID: "official-codex"),
            "official-codex", "无任何第三方卡 → 官方兜底（Codex 无卡用户的进入入口）"
        )
        XCTAssertNil(
            AggregationPanelView.resolveDefaultCandidate(
                active: .official, profileIDs: [], officialProfileID: nil),
            "Claude 侧无官方卡合成 → 无候选"
        )
    }

    /// 陈旧横幅正文与标题不得互相矛盾：`unverified`（进程表不可得）时 `others` 只表示
    /// 「上次确认后目录或登录变了」（`CodexStaleClientDetector`），不等于「有客户端还在用
    /// 旧目录」——那一态下发 `staleOthersBody` 会与 `staleUnverifiedTitle` 直接打架。
    func test_staleMessage_unverifiedOthersGetsNoContradictoryBody() throws {
        let view = try makeView()
        let strings = Strings.zhHans

        XCTAssertEqual(
            view.staleMessage(CodexStaleClients(daemon: false, others: true, unverified: true)),
            nil,
            "unverified：标题才说不知道有谁在跑，正文不能断言有客户端在用旧目录"
        )
        XCTAssertEqual(
            view.staleMessage(CodexStaleClients(daemon: false, others: true, unverified: false)),
            strings.providerAggregationStaleOthersBody,
            "进程表可得、确认后目录变过 → 照常给其余客户端指引"
        )
        XCTAssertEqual(
            view.staleMessage(CodexStaleClients(daemon: true, others: true, unverified: true)),
            strings.providerAggregationStaleDaemonBody,
            "守护进程陈旧优先：它不受 unverified 影响"
        )
        XCTAssertNil(view.staleMessage(CodexStaleClients(daemon: false, others: false)))
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

    /// R23 修复的回归：没动过编辑区时，保存值必须**跟着表单当前映射**推导，而不是把打开时的
    /// 推导值冻住。冻住的后果是静默偏离——`modelMapping` 存新模型、发布列表留旧模型，
    /// 用户改的角色模型既不进发布列表也不报错。
    @MainActor
    func test_stackModelsForSave_followsLiveMappingWhenUntouched() throws {
        let beforeEdit = ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk",
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(sonnet: "glm-5.3-air", opus: "glm-5.3")
        )
        // 注意 normalize 会按模型名去重：modelOverride 与 opus 同为 glm-5.3 → 合并成一行。
        XCTAssertEqual(
            (ProfileEditorView.stackModelsForSave(nil, profile: beforeEdit) ?? []).map(\.model),
            ["glm-5.3", "glm-5.3-air"]
        )

        // 用户在映射区把 opus 改成新模型（编辑区没动过）→ 保存值必须反映新映射。
        let afterEdit = ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk",
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(sonnet: "glm-5.3-air", opus: "glm-6")
        )
        XCTAssertEqual(
            (ProfileEditorView.stackModelsForSave(nil, profile: afterEdit) ?? []).map(\.model),
            ["glm-5.3", "glm-6", "glm-5.3-air"],
            "未动过的编辑区必须按当前映射实时推导，不能冻结成打开时的值"
        )

        // 动过 → 用编辑态（normalize 后），不再看映射。
        XCTAssertEqual(
            ProfileEditorView.stackModelsForSave(
                [ClaudeStackModel(model: "k3[1m]", displayName: nil, oneM: false)],
                profile: afterEdit
            ),
            [ClaudeStackModel(model: "k3", displayName: nil, oneM: true)]
        )
    }

    /// R23 的关键不变量：`[]` 是**非 nil 的空数组**，`??` 不得用推导值把它顶掉——
    /// 否则用户清空列表后下次打开又长出模型，删除被静默还原（R7）。
    @MainActor
    func test_stackModelsForSave_clearedListIsNotResurrectedByFallback() throws {
        let profile = ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk",
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(opus: "glm-5.3")
        )
        XCTAssertEqual(profile.aggregationModels.count, 2, "该档案的推导值非空，足以暴露被顶掉")

        let saved = ProfileEditorView.stackModelsForSave([], profile: profile)
        XCTAssertEqual(saved, [], "主动清空必须落成 []，不得回落到映射推导值")

        // 落进 profile 后仍是 []（`ProviderProfile.swift:190` 对非 nil 的 stackModels 原样返回，
        // 空数组因此能一路传到发布侧的空发布分支）。
        let view = makeEditor(tool: .claudeCode, profile: nil)
        let roundTripped = view.makeProfile(
            name: "GLM", baseURL: profile.baseURL, token: "sk",
            modelOverride: nil, reasoningEffort: nil, codexModels: nil, modelMapping: nil,
            extraEnv: [:],
            stackModels: saved,
            codexModelDisplayNames: nil
        )
        XCTAssertEqual(roundTripped.stackModels, [])
        XCTAssertEqual(roundTripped.aggregationModels, [], "空数组不得被推导值顶掉")
    }

    /// 直连模式打开（发布列表不可见）的保存口径：原值保留，不按映射推导固化。
    /// 固化的危害：直连改角色映射就静默覆盖用户显式配置的发布列表。
    @MainActor
    func test_stackModelsForSave_directModeKeepsExistingListUntouched() throws {
        let existing = [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: true)]
        let profile = ProviderProfile(
            id: "kimi", name: "Kimi", tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding", token: "sk",
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(opus: "glm-5.3"),
            stackModels: existing
        )

        // 编辑既有档案：即便表单映射已改成与显式列表不同的值，保存也不得动它。
        XCTAssertEqual(
            ProfileEditorView.stackModelsForSave(
                nil, profile: profile, aggregating: false, existing: profile.stackModels
            ),
            existing
        )
        // 新增档案（existing = nil）：保持「未配置、跟着映射推导」语义，不为空列表固化。
        XCTAssertNil(
            ProfileEditorView.stackModelsForSave(
                nil, profile: profile, aggregating: false, existing: nil
            )
        )
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
        XCTAssertNil(ProfileEditorView.codexDisplayNamesForSave([("kimi-k3", "", "")]))
        XCTAssertNil(ProfileEditorView.codexDisplayNamesForSave([]))
        XCTAssertEqual(
            ProfileEditorView.codexDisplayNamesForSave([("kimi-k3", "Kimi K3", ""), ("kimi-k2", "", "")]),
            ["Kimi K3", ""],
            "有任一个非空就原样写（含空串占位），保住按位对齐"
        )
    }

    /// 回归：窗口平行数组必须与**过滤后**的模型列表同源对齐。删掉中间一行后模型左移，
    /// 窗口若还按档案原数组的下标读取，每个幸存模型都会拿到邻居的窗口（R13 让窗口靠
    /// 「原样携带」存活，Task 11 的行删除打破了这份按位对齐）。
    @MainActor
    func test_save_codexContextWindowsFollowSurvivingRows() throws {
        let view = makeEditor(tool: .codex, profile: nil)

        // 档案原状：三个模型、三个窗口（按位平行）。用户删掉中间那行。
        let surviving = ProfileEditorView.alignedCodexSaveRows(
            models: ["glm-5.3", "kimi-k3", "kimi-k2"],
            displayNames: ["GLM", "Kimi K3", ""],
            windows: ["200000", "256000", "128000"]
        ).filter { $0.model != "kimi-k3" }

        let saved = view.makeProfile(
            name: "GLM", baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk",
            modelOverride: nil, reasoningEffort: nil,
            codexModels: surviving.map(\.model), modelMapping: nil, extraEnv: [:],
            stackModels: nil,
            codexModelDisplayNames: ProfileEditorView.codexDisplayNamesForSave(surviving),
            codexModelContextWindows: ProfileEditorView.codexContextWindowsForSave(surviving)
        )
        XCTAssertEqual(saved.codexModels, ["glm-5.3", "kimi-k2"])
        XCTAssertEqual(
            saved.modelContextWindows, ["200000", "128000"],
            "窗口跟着幸存行平移，不得把 256000（已删那行的）留给 kimi-k2"
        )
        XCTAssertEqual(saved.codexModelEntries.map(\.contextWindow), [200_000, 128_000])

        // 一个窗口都没配 → nil（不写键，保持既有落盘形状）。
        XCTAssertNil(ProfileEditorView.codexContextWindowsForSave([("glm-5.3", "", "")]))
        XCTAssertNil(ProfileEditorView.codexContextWindowsForSave([]))
        XCTAssertEqual(
            ProfileEditorView.codexContextWindowsForSave([("glm-5.3", "", "200000"), ("kimi-k2", "", "")]),
            ["200000", ""],
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
    var hasStashedLogin = false
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
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
    ) throws {}
    func clearAggregation() throws {}
    func currentContractDigest() -> String { "" }
    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
    ) -> String { "" }
}
