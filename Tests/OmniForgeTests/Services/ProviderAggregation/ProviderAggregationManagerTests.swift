import XCTest
@testable import OmniForge

/// 聚合编排管理器：进入先起代理后写配置、代理起不来不写配置、Codex 登录收纳/还原
/// （官方默认不收纳）、快照进入与恢复、按工具独立、单工具退出不停代理、名单与 key 保留、
/// 官方账号禁入、默认成员聚合期间禁移、删 profile 摘名单留 key、契约未变不重写、
/// 部分写入语义、看门狗重启与回落。
@MainActor
final class ProviderAggregationManagerTests: XCTestCase {
    private var tmpDir: URL!
    private var profileStore: StubProfileStore!
    private var backupStore: StubBackupStore!
    private var loginStash: StubLoginStashStore!
    private var staleDetector: StubStaleDetector!
    private var proxy: StubProxy!
    private var claudeWriter: StubClaudeWriter!
    private var codexWriter: StubCodexWriter!
    private var manager: ProviderAggregationManager!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAggregationManagerTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        profileStore = StubProfileStore()
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .claudeCode,
                baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
                stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
            ),
            ProviderProfile(
                id: "glm", name: "GLM", tool: .claudeCode,
                baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
            ),
            ProviderProfile(
                id: "anthropic-official", name: "Anthropic", tool: .claudeCode,
                baseURL: "https://api.anthropic.com", token: "sk-official"
            ),
            ProviderProfile(
                id: "deepseek", name: "DeepSeek", tool: .codex,
                baseURL: "https://api.deepseek.com/v1", token: "sk-ds",
                codexModels: ["deepseek-v4-pro"]
            ),
        ]
        backupStore = StubBackupStore()
        loginStash = StubLoginStashStore()
        staleDetector = StubStaleDetector()
        proxy = StubProxy()
        claudeWriter = StubClaudeWriter()
        codexWriter = StubCodexWriter()
        manager = makeManager()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeManager(withCodexWriter codexWriterOverride: AggregationCodexConfigWriting? = nil) -> ProviderAggregationManager {
        ProviderAggregationManager(
            profileStore: profileStore,
            backupStore: backupStore,
            stackStore: AggregationStackStore(stackURL: tmpDir.appendingPathComponent("stack.json")),
            pendingStore: AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending.json")),
            loginStashStore: loginStash,
            staleDetector: staleDetector,
            proxy: proxy,
            claudeWriter: claudeWriter,
            codexWriter: codexWriterOverride ?? codexWriter,
            profiles: profileStore.stubProfiles
        )
    }

    private func makeManager(activationRefresher: ProviderActivationRefreshing) -> ProviderAggregationManager {
        ProviderAggregationManager(
            profileStore: profileStore,
            backupStore: backupStore,
            stackStore: AggregationStackStore(stackURL: tmpDir.appendingPathComponent("stack.json")),
            pendingStore: AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending.json")),
            loginStashStore: loginStash,
            staleDetector: staleDetector,
            proxy: proxy,
            claudeWriter: claudeWriter,
            codexWriter: codexWriter,
            profiles: profileStore.stubProfiles,
            activationRefresher: activationRefresher
        )
    }

    /// 官方 Codex fixture：官方登录走 `auth.json` OAuth，**无静态 token**（`isOfficial`
    /// 按宿主判定、与 token 无关）；`codexModels` 是官方模型名。
    private var officialCodexProfile: ProviderProfile {
        ProviderProfile(
            id: "openai-official",
            name: "OpenAI",
            tool: .codex,
            baseURL: "https://api.openai.com/v1",
            token: "",
            codexModels: ["gpt-5-codex"]
        )
    }

    /// 第三方 Codex fixture（默认切换的对照方）。
    private var thirdPartyCodexProfile: ProviderProfile {
        ProviderProfile(
            id: "deepseek",
            name: "DeepSeek",
            tool: .codex,
            baseURL: "https://api.deepseek.com/v1",
            token: "sk-ds",
            codexModels: ["deepseek-v4-pro"]
        )
    }

    // MARK: - 进入/退出

    func test_enterAggregation_startsProxyBeforeWritingConfig() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertTrue(manager.isProxyRunning)
        XCTAssertEqual(claudeWriter.lastAppliedPort, manager.resolvedPort)
        XCTAssertEqual(claudeWriter.lastDefaultProfile?.id, "kimi")
    }

    func test_enterAggregation_doesNotWriteConfigWhenProxyFailsToStart() {
        proxy.stubStartError = AggregationProxyError.allPortsTaken
        XCTAssertThrowsError(try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi"))
        XCTAssertNil(claudeWriter.lastAppliedPort)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
    }

    func test_enterAggregation_stashesCodexOfficialLogin() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertEqual(loginStash.stashCallCount, 1)
        XCTAssertEqual(loginStash.restoreCallCount, 0, "第三方默认：只收纳，不还原")
    }

    func test_enterAggregation_allowsOfficialProfileWithoutStaticToken() throws {
        profileStore.stubProfiles = [officialCodexProfile]   // token 为空
        manager = makeManager()
        loginStash.hasNativeLogin = true
        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")
        XCTAssertEqual(manager.mode(tool: .codex), .aggregation, "官方登录走 auth.json OAuth，无静态 token 也能做默认那家（SPEC 3 契约的前提）")
    }

    func test_enterAggregation_rejectsThirdPartyProfileWithoutStaticToken() {
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "keyless", name: "Keyless", tool: .codex,
                baseURL: "https://api.keyless.com/v1", token: "",
                codexModels: ["keyless-v1"]
            )
        ]
        manager = makeManager()
        XCTAssertThrowsError(try manager.enterAggregation(tool: .codex, defaultProfileID: "keyless")) { error in
            XCTAssertEqual(error as? AggregationManagerError, .incompleteConnection(id: "keyless"),
                           "第三方无静态 token 仍不得借官方登录的路（SPEC 0 / P1-11）")
        }
        XCTAssertEqual(manager.mode(tool: .codex), .direct)
        XCTAssertEqual(loginStash.stashCallCount, 0)
    }

    func test_enterAggregation_skipsLoginStashWhenCodexDefaultIsOfficial() throws {
        profileStore.stubProfiles = [officialCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true
        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")
        XCTAssertEqual(loginStash.stashCallCount, 0, "官方默认：登录走 auth.json，无需收纳（SPEC 3 契约 3）")
        XCTAssertEqual(loginStash.restoreCallCount, 1, "此前若已收纳 → 还原")
    }

    /// 方案 B（SPEC 2026-10-17）：官方默认与第三方同形状——custom 表 + 目录恒写。
    func test_enterAggregation_officialCodexDefaultWritesProxyShapeAndCatalog() throws {
        let configURL = tmpDir.appendingPathComponent("config.toml")
        let catalogURL = tmpDir.appendingPathComponent("omniforge-stack-catalog.json")
        let modelsCacheURL = tmpDir.appendingPathComponent(ProviderSwitchPaths.codexModelsCacheFileName)
        let realCodexWriter = AggregationCodexConfigWriter(configURL: configURL, catalogURL: catalogURL, modelsCacheURL: modelsCacheURL)
        profileStore.stubProfiles = [officialCodexProfile]
        let manager = makeManager(withCodexWriter: realCodexWriter)
        loginStash.hasNativeLogin = true

        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")

        let doc = try XCTUnwrap(TOMLFile.parse(try String(contentsOf: configURL, encoding: .utf8)))
        XCTAssertEqual(doc.stringValue(key: "model_provider", table: nil), "custom", "官方默认同走本机代理")
        XCTAssertEqual(doc.stringValue(key: "model_catalog_json", table: nil), ProviderSwitchPaths.codexAggregationCatalogFileName)
        XCTAssertEqual(doc.booleanValue(key: "requires_openai_auth", table: ["model_providers", "custom"]), true)
        XCTAssertEqual(doc.stringValue(key: "model", table: nil), "gpt-5-codex", "官方默认照写模型选择")
        // models_cache 缺失的安全降级：目录仍写（成员行），官方行暂缺。
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    /// 官方默认但官方登录（auth.json）不在场 → 事前挡下并指路（不进只收 401 的形态）。
    func test_enterAggregation_rejectsOfficialDefaultWithoutNativeLogin() {
        profileStore.stubProfiles = [officialCodexProfile]
        manager = makeManager()
        // loginStash.hasNativeLogin 默认 false。
        XCTAssertThrowsError(try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")) { error in
            XCTAssertEqual(error as? AggregationManagerError, .officialLoginRequired)
        }
        XCTAssertEqual(manager.mode(tool: .codex), .direct, "校验失败不进聚合")
        XCTAssertEqual(loginStash.stashCallCount, 0)
    }

    /// 聚合中换默认那家 → 登录收纳态跟着换（SPEC 3 / P0-3 契约 3）。
    /// 官方默认进入（不收纳）→ 切第三方：必须收纳，否则官方 auth.json 在第三方路由期间仍然裸露；
    /// 再切回官方：必须还原，否则官方分支依赖的登录还被收着。
    func test_setDefault_movesLoginStashWithDefaultOfficialness() throws {
        profileStore.stubProfiles = [officialCodexProfile, thirdPartyCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true

        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")
        XCTAssertEqual(loginStash.stashCallCount, 0, "官方默认进入：不收纳")
        // 官方分支顺带 restore——首次进入本就没有 stash，是无副作用空操作。
        XCTAssertEqual(loginStash.restoreCallCount, 1)

        try manager.addMember("deepseek", tool: .codex)
        try manager.setDefault("deepseek", tool: .codex)
        XCTAssertEqual(manager.toolStack(.codex).members.first, "deepseek")
        XCTAssertEqual(loginStash.stashCallCount, 1, "切到第三方默认：收纳官方登录")
        XCTAssertEqual(loginStash.restoreCallCount, 1, "收纳路径不还原")

        try manager.setDefault("openai-official", tool: .codex)
        XCTAssertEqual(manager.toolStack(.codex).members.first, "openai-official")
        XCTAssertEqual(loginStash.stashCallCount, 1, "切回官方默认：不再收纳")
        XCTAssertEqual(loginStash.restoreCallCount, 2, "并还原此前收纳的登录")
    }

    // MARK: - 代理快照的官方透传位

    /// 官方默认：plain 目标带透传位 —— 代理不得把客户端自己的 OAuth `Authorization`
    /// 覆盖成占位凭证（官方 profile 无静态 token，覆盖即 401；SPEC 3 契约 4）。
    func test_proxySnapshot_officialDefaultTargetPassesAuthorizationThrough() throws {
        profileStore.stubProfiles = [officialCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true

        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")

        let target = try XCTUnwrap(manager.proxySnapshot().defaultTargets[.codex])
        XCTAssertTrue(target.passesThroughAuthorization)
    }

    /// 第三方默认：不带透传位 —— 仍按占位凭证换成真实 token。
    func test_proxySnapshot_thirdPartyDefaultTargetKeepsCredentialRewrite() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")

        let target = try XCTUnwrap(manager.proxySnapshot().defaultTargets[.codex])
        XCTAssertFalse(target.passesThroughAuthorization)
    }

    /// Claude 侧官方默认（api.anthropic.com + 静态 API key）**不**透传：
    /// Claude 投影写死 `ANTHROPIC_AUTH_TOKEN = PROXY_MANAGED`，透传等于把占位符
    /// 发给 Anthropic → 每个请求都 401（SPEC §3 收尾「Claude 侧不动」：官方默认照
    /// BASE_URL + token 替换路径）。透传位只属于 Codex 官方（OAuth、无静态 token）。
    func test_proxySnapshot_officialClaudeDefaultTargetKeepsCredentialRewrite() throws {
        profileStore.stubProfiles = [ProviderProfile(
            id: "anthropic-official", name: "Anthropic", tool: .claudeCode,
            baseURL: "https://api.anthropic.com", token: "sk-official"
        )]
        manager = makeManager()

        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "anthropic-official")

        let target = try XCTUnwrap(manager.proxySnapshot().defaultTargets[.claudeCode])
        XCTAssertFalse(target.passesThroughAuthorization)
        XCTAssertEqual(target.token, "sk-official", "静态 API key 仍作为替换凭证下发给上游")
    }

    /// 聚合中换默认那家 → 透传位跟着翻（与登录收纳态同一条跟随规则）。
    /// 官方默认进入 → 切第三方默认：必须摘掉透传位，否则第三方路由会把客户端的
    /// `Authorization` 原样透传给第三方（它的 token 根本不在那里）。
    func test_proxySnapshot_passthroughBitFollowsDefaultSwitch() throws {
        profileStore.stubProfiles = [officialCodexProfile, thirdPartyCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true

        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")
        XCTAssertTrue(manager.proxySnapshot().defaultTargets[.codex]?.passesThroughAuthorization ?? false)

        try manager.addMember("deepseek", tool: .codex)
        try manager.setDefault("deepseek", tool: .codex)
        XCTAssertFalse(manager.proxySnapshot().defaultTargets[.codex]?.passesThroughAuthorization ?? true)
    }

    func test_exitAggregation_restoresLoginAndStopsProxyWhenNoToolAggregates() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        try manager.exitAggregation(tool: .codex)
        XCTAssertEqual(loginStash.restoreCallCount, 1)
        XCTAssertFalse(manager.isProxyRunning)
    }

    func test_enterAggregationAsync_and_exitAggregationAsync() async throws {
        try await manager.enterAggregationAsync(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertTrue(manager.isProxyRunning)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .aggregation)
        XCTAssertEqual(claudeWriter.lastDefaultProfile?.id, "kimi")

        try await manager.exitAggregationAsync(tool: .claudeCode)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
        XCTAssertFalse(manager.isProxyRunning)
    }

    /// 模式切换成功后必须驱动直连激活态重算：聚合投影会把配置指向回环代理地址，
    /// 若不刷新，`ProviderSwitchManager.activeByTool` 会把代理地址锁成未托管态，
    /// 退出聚合后「未托管配置」横幅残留（2026-10-17 实测回归）。
    func test_enterAggregationAsync_notifiesActivationRefresher() async throws {
        let refresher = StubActivationRefresher()
        manager = makeManager(activationRefresher: refresher)
        try await manager.enterAggregationAsync(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertEqual(refresher.refreshCount, 1)
    }

    func test_exitAggregationAsync_notifiesActivationRefresher() async throws {
        let refresher = StubActivationRefresher()
        manager = makeManager(activationRefresher: refresher)
        try await manager.enterAggregationAsync(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertEqual(refresher.refreshCount, 1)   // 进入即同步一次
        try await manager.exitAggregationAsync(tool: .claudeCode)
        XCTAssertEqual(refresher.refreshCount, 2)   // 退出再同步一次
    }

    /// 代理起不来 = 什么都没写：此时不得触发激活态刷新。
    func test_enterAggregationAsync_doesNotNotifyActivationRefresherWhenProxyStartFails() async {
        let refresher = StubActivationRefresher()
        manager = makeManager(activationRefresher: refresher)
        proxy.stubStartError = AggregationProxyError.allPortsTaken
        do {
            try await manager.enterAggregationAsync(tool: .claudeCode, defaultProfileID: "kimi")
            XCTFail("代理启动失败应抛错")
        } catch {
            // 预期路径：抛错且不驱动刷新
        }
        XCTAssertEqual(refresher.refreshCount, 0)
    }

    func test_refresh_skipsCommitWhenStackUnchanged() {
        let initialStack = manager.stack
        manager.refresh()
        XCTAssertEqual(manager.stack, initialStack)
    }

    func test_exitAggregation_restoresPreAggregationSnapshot() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertEqual(backupStore.snapshotCallCount, 1)   // 进入聚合的写流程以快照开头
        try manager.exitAggregation(tool: .claudeCode)
        XCTAssertEqual(backupStore.restoreCallCount, 1)   // 退出 = 从进入前快照恢复直连配置
    }

    func test_enterAndExitAggregation_observeCodexLoginGeneration() throws {
        // 第三方分支在 stash 前、退出在 restore 后各记一代（P1-9 三处挂点）。
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertEqual(loginStash.stashCallCount, 1)
        XCTAssertEqual(staleDetector.observeLoginCallCount, 1)
        try manager.exitAggregation(tool: .codex)
        XCTAssertEqual(loginStash.restoreCallCount, 1)
        XCTAssertEqual(staleDetector.observeLoginCallCount, 2)
    }

    func test_enterAggregation_observesLoginGenerationAfterOfficialRestore() throws {
        profileStore.stubProfiles = [officialCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true
        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")
        XCTAssertEqual(staleDetector.observeLoginCallCount, 1, "官方分支：还原之后记一代（登录从无到有）")
    }

    func test_enterAggregation_doesNotObserveLoginGenerationForClaudeCode() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertEqual(staleDetector.observeLoginCallCount, 0, "登录代次只管 Codex")
    }

    func test_acknowledgeStaleClients_asksDetectorToRecordCurrentFingerprints() {
        manager.acknowledgeStaleClients()
        XCTAssertEqual(staleDetector.acknowledgeCallCount, 1)
    }

    func test_enterAggregation_isIndependentPerTool() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertEqual(manager.mode(tool: .codex), .aggregation)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
    }

    func test_exitOneToolKeepsProxyRunningWhileOtherStillAggregates() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        try manager.exitAggregation(tool: .codex)
        XCTAssertTrue(manager.isProxyRunning)
    }

    /// 跨工具同名卡（id 只在单工具目录内唯一）：两侧都建 DeepSeek 卡时，
    /// Codex 聚合按 (id, tool) 定位，不得误命中 Claude 那张报「不属于当前工具」。
    func test_enterAggregation_resolvesSameIDCardWithinTool() throws {
        let claudeDeepseek = ProviderProfile(
            id: "deepseek", name: "DeepSeek", tool: .claudeCode,
            baseURL: "https://api.deepseek.com/anthropic", token: "sk-claude"
        )
        let codexDeepseek = ProviderProfile(
            id: "deepseek", name: "DeepSeek", tool: .codex,
            baseURL: "https://api.deepseek.com/v1", token: "sk-codex",
            codexModels: ["deepseek-v4-pro"]
        )
        profileStore.stubProfiles = [claudeDeepseek, codexDeepseek]   // Claude 在前：旧的仅按 id 查找会命中它
        manager = makeManager()
        loginStash.hasNativeLogin = true

        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertEqual(manager.mode(tool: .codex), .aggregation)
        XCTAssertEqual(codexWriter.lastDefaultProfile?.baseURL, "https://api.deepseek.com/v1",
                       "命中的必须是 Codex 那张同名卡")
        // Claude 侧同名卡不受牵连，Claude 栈未被写。
        XCTAssertFalse(manager.isAggregating(.claudeCode))
    }

    // MARK: - 合成官方卡（方案 B：官方经默认位进聚合）

    /// Codex 侧无任何官方卡片 → 聚合上下文注入合成官方卡（模型列表来自官方缓存）。
    func test_loadProfilesWithSyntheticOfficial_injectsWhenCodexHasNoOfficialCard() throws {
        let cacheURL = tmpDir.appendingPathComponent(ProviderSwitchPaths.codexModelsCacheFileName)
        let root: [String: Any] = ["models": [["slug": "gpt-5.6-sol"], ["slug": "gpt-6-astra"]]]
        try JSONSerialization.data(withJSONObject: root).write(to: cacheURL)

        profileStore.stubProfiles = [thirdPartyCodexProfile]
        let profiles = ProviderAggregationManager.loadProfilesWithSyntheticOfficial(
            profileStore: profileStore, modelsCacheURL: cacheURL, fileManager: .default
        )
        XCTAssertEqual(profiles.map(\.id), ["deepseek", ProviderAggregationManager.officialCodexProfileID])
        let official = try XCTUnwrap(profiles.first { $0.id == ProviderAggregationManager.officialCodexProfileID })
        XCTAssertTrue(official.isOfficial, "合成卡走官方谓词（baseURL 为官方域）")
        XCTAssertEqual(official.codexModelList, ["gpt-5.6-sol", "gpt-6-astra"], "模型列表与官方缓存同源")
    }

    /// 用户已有自建官方卡（官方域 baseURL）→ 不再注入，避免两张国方卡并存。
    func test_loadProfilesWithSyntheticOfficial_skipsWhenUserHasOwnOfficialCard() {
        let userOfficial = ProviderProfile(
            id: "my-openai", name: "My OpenAI", tool: .codex,
            baseURL: "https://api.openai.com/v1", token: "",
            codexModels: ["gpt-5.6-sol"]
        )
        profileStore.stubProfiles = [userOfficial]
        let profiles = ProviderAggregationManager.loadProfilesWithSyntheticOfficial(
            profileStore: profileStore, modelsCacheURL: tmpDir.appendingPathComponent("nope.json"), fileManager: .default
        )
        XCTAssertEqual(profiles.map(\.id), ["my-openai"], "已有官方卡时不注入合成卡")
    }

    /// Claude 侧不合成（Claude 官方无 OAuth 无凭证形态）。
    func test_loadProfilesWithSyntheticOfficial_neverInjectsForClaude() {
        profileStore.stubProfiles = []
        let profiles = ProviderAggregationManager.loadProfilesWithSyntheticOfficial(
            profileStore: profileStore, modelsCacheURL: tmpDir.appendingPathComponent("nope.json"), fileManager: .default
        )
        XCTAssertFalse(profiles.contains { $0.tool == .claudeCode && $0.isOfficial })
    }

    // MARK: - 成员管理

    func test_exitAggregation_retainsMembersAndKeys() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm", tool: .claudeCode)
        try manager.exitAggregation(tool: .claudeCode)
        XCTAssertEqual(manager.toolStack(.claudeCode).members, ["kimi", "glm"])
        XCTAssertEqual(manager.toolStack(.claudeCode).keys["glm"], "glm")
    }

    func test_addMember_allocatesPermanentKey() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm", tool: .claudeCode)
        XCTAssertEqual(manager.toolStack(.claudeCode).keyOf(profileID: "glm"), "glm")
    }

    func test_addMember_rejectsOfficialAccount() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertThrowsError(try manager.addMember("anthropic-official", tool: .claudeCode))
        XCTAssertFalse(manager.toolStack(.claudeCode).isMember("anthropic-official"))
    }

    func test_removeDefaultMemberIsRejectedWhileAggregating() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        XCTAssertThrowsError(try manager.removeMember("kimi", tool: .claudeCode))
    }

    func test_removeDefaultMemberIsAllowedOnceAggregationExited() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.exitAggregation(tool: .claudeCode)
        try manager.removeMember("kimi", tool: .claudeCode)
        XCTAssertFalse(manager.toolStack(.claudeCode).isMember("kimi"))
        XCTAssertNotNil(manager.toolStack(.claudeCode).keys["kimi"])   // key 仍保留
    }

    func test_deletingProfileRemovesItFromMembersButKeepsKey() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm", tool: .claudeCode)
        profileStore.stubProfiles.removeAll { $0.id == "glm" }
        manager.refresh()
        XCTAssertFalse(manager.toolStack(.claudeCode).isMember("glm"))
        XCTAssertNotNil(manager.toolStack(.claudeCode).keys["glm"])
    }

    func test_addMember_skipsRewriteWhenContractUnchanged() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        let writesBefore = claudeWriter.applyCount
        try manager.addMember("kimi", tool: .claudeCode)   // 已在名单里 → 无变化
        XCTAssertEqual(claudeWriter.applyCount, writesBefore)
    }

    // MARK: - 成员兼容开关合并

    func test_enterAggregation_passesOnlyDefaultMemberSwitchesWhenAlone() throws {
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .claudeCode,
                baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
                stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)],
                extraEnv: ["ENABLE_TOOL_SEARCH": "1"]
            )
        ]
        manager = makeManager()
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        // 只有默认一家 → 合并不执行，默认那家的开关原样进投影
        XCTAssertEqual(claudeWriter.lastMemberSwitches, ["ENABLE_TOOL_SEARCH": "1"])
    }

    func test_addMember_mergesMemberSwitchesIntoProjection() throws {
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .claudeCode,
                baseURL: "https://api.kimi.com/coding", token: "sk-kimi",
                stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)],
                extraEnv: ["ENABLE_TOOL_SEARCH": "1"]
            ),
            ProviderProfile(
                id: "glm", name: "GLM", tool: .claudeCode,
                baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm",
                extraEnv: ["CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "true", "ENABLE_TOOL_SEARCH": "yes"]
            ),
        ]
        manager = makeManager()
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm", tool: .claudeCode)
        // ANY 组取第一个"要关"成员的原值；ALL 组保留默认那家的既有值（不是成员的 yes）
        XCTAssertEqual(claudeWriter.lastMemberSwitches, [
            "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "true",
            "ENABLE_TOOL_SEARCH": "1",
        ])
    }

    // MARK: - Codex 成员发布源

    func test_codexPublishedModels_prefersEntryDisplayNameAndWindow() throws {
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .codex,
                baseURL: "https://api.kimi.com/v1", token: "sk-kimi",
                codexModels: ["kimi-k3"],
                modelDisplayNames: ["Kimi K3"],
                modelContextWindows: ["400000"],
                extraEnv: ["model_context_window": "1000000"]
            )
        ]
        manager = makeManager()
        try manager.enterAggregation(tool: .codex, defaultProfileID: "kimi")
        let published = manager.publishedModels(tool: .codex)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].model, "kimi-k3")
        XCTAssertEqual(published[0].displayName, "Kimi K3")
        XCTAssertEqual(published[0].window, 400_000, "条目窗口优先于 extraEnv 全局口径")
    }

    func test_codexPublishedModels_fallsBackWhenEntryValuesAbsent() throws {
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .codex,
                baseURL: "https://api.kimi.com/v1", token: "sk-kimi",
                codexModels: ["kimi-k3", "kimi-k2"],
                modelDisplayNames: ["Kimi K3", ""],
                modelContextWindows: ["", "400000"],
                extraEnv: ["model_context_window": "1000000"]
            )
        ]
        manager = makeManager()
        try manager.enterAggregation(tool: .codex, defaultProfileID: "kimi")
        let published = manager.publishedModels(tool: .codex)
        XCTAssertEqual(published.map(\.displayName), ["Kimi K3", "kimi-k2"], "空串=未配置 → 回落模型名")
        XCTAssertEqual(published.map(\.window), [1_000_000, 400_000], "窗口空串 → 回落 extraEnv 全局口径")
    }

    // MARK: - 快照刷新（面板挂载时补列）

    /// 面板 `.task` 靠 `refresh()` 把启动期那份 profile 快照刷成当前的：`production()`
    /// 在用户还没建任何东西时就列举过一次，此后新建的 profile 不在快照里 —— 不进「可加入」
    /// 名单，且作为默认那家时 `enterAggregation` 会抛 profileNotFound（切换失败）。
    func test_refresh_picksUpProfilesCreatedAfterLaunch() {
        XCTAssertFalse(manager.joinableProfileIDs(tool: .claudeCode).contains("moonshot"))

        profileStore.stubProfiles.append(ProviderProfile(
            id: "moonshot", name: "Moonshot", tool: .claudeCode,
            baseURL: "https://api.moonshot.cn/v1", token: "sk-moonshot"
        ))
        manager.refresh()

        XCTAssertTrue(manager.joinableProfileIDs(tool: .claudeCode).contains("moonshot"))
    }

    /// 刷新同时摘掉已删除的成员（key 永不回收——重新加入拿回原 key，旧会话里的 id 继续有效）。
    func test_refresh_prunesDeletedMembersButKeepsKeys() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        try manager.addMember("glm", tool: .claudeCode)

        profileStore.stubProfiles.removeAll { $0.id == "glm" }
        manager.refresh()

        XCTAssertEqual(manager.toolStack(.claudeCode).members, ["kimi"])
        XCTAssertEqual(manager.toolStack(.claudeCode).keys["glm"], "glm", "key 一经分配永不回收")
    }

    // MARK: - 部分写入与看门狗

    func test_partialFailureReportsPartialTrueAfterPublish() throws {
        codexWriter.stubApplyError = StubError.writeFailed
        XCTAssertThrowsError(try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek"))
        XCTAssertEqual(manager.lastPartialWrite, true)
        XCTAssertNotNil(pendingStore().load())
        // published 在发布前已置 true（见实现），恢复判定应为 .rolledForward（幂等补完），而非丢弃
        XCTAssertEqual(pendingStore().load()?.published, true)
    }

    func test_proxyUnexpectedStop_restartsThenFallsBackAfterRepeatedFailures() throws {
        try manager.enterAggregation(tool: .claudeCode, defaultProfileID: "kimi")
        proxy.simulateUnexpectedStop()          // 第一次异常退出 → 看门狗自动重启
        XCTAssertTrue(manager.isProxyRunning)
        proxy.stubStartError = AggregationProxyError.allPortsTaken
        proxy.simulateUnexpectedStop()          // 重启失败 → 回落直连并报错
        XCTAssertFalse(manager.isProxyRunning)
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct)
    }

    private func pendingStore() -> AggregationPendingStore {
        AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending.json"))
    }
}

// MARK: - Stubs

private enum StubError: Error, Equatable {
    case writeFailed
}

/// 激活态同步替身：记录被驱动重算的次数（模式切换契约）。
private final class StubActivationRefresher: ProviderActivationRefreshing {
    var refreshCount = 0

    func refreshActivationState() {
        refreshCount += 1
    }
}

private final class StubProxy: AggregationProxying {
    var isRunning = false
    var resolvedPort: UInt16?
    var onUnexpectedStop: (() -> Void)?
    var stubStartError: Error?

    func start() throws {
        if let stubStartError { throw stubStartError }
        isRunning = true
        resolvedPort = 15721
    }

    func stop() {
        isRunning = false
        resolvedPort = nil
    }

    /// 模拟异常退出：清运行态并触发看门狗回调。
    func simulateUnexpectedStop() {
        isRunning = false
        resolvedPort = nil
        onUnexpectedStop?()
    }
}

private final class StubProfileStore: ProviderProfileStoring {
    var stubProfiles: [ProviderProfile] = []
    func list(for tool: ProviderTool) -> [ProviderProfile] {
        stubProfiles.filter { $0.tool == tool }
    }
    func upsert(_ profile: ProviderProfile) throws {}
    func delete(_ profile: ProviderProfile) throws {}
    func adopt(name: String, tool: ProviderTool, baseURL: String, token: String, modelOverride: String?) throws -> ProviderProfile {
        ProviderProfile(id: "", name: name, tool: tool, baseURL: baseURL, token: token, modelOverride: modelOverride)
    }
}

private final class StubBackupStore: ProviderBackupStoring {
    var snapshotCallCount = 0
    var restoreCallCount = 0
    private var backups: [ProviderTool: [ProviderBackup]] = [:]

    func snapshot(tool: ProviderTool, of configURL: URL) throws -> ProviderBackup {
        snapshotCallCount += 1
        let backup = ProviderBackup(id: "stub-\(snapshotCallCount)", tool: tool, date: Date())
        backups[tool, default: []].insert(backup, at: 0)
        return backup
    }

    func list(tool: ProviderTool) -> [ProviderBackup] {
        backups[tool] ?? []
    }

    func content(of backup: ProviderBackup) throws -> String { "" }

    func restore(_ backup: ProviderBackup, to configURL: URL) throws {
        restoreCallCount += 1
    }
}

private final class StubLoginStashStore: CodexLoginStashStoring {
    var hasNativeLogin = false
    var stashCallCount = 0
    var restoreCallCount = 0

    func stash() throws -> Bool {
        stashCallCount += 1
        return hasNativeLogin
    }

    func restore() throws -> Bool {
        restoreCallCount += 1
        return false
    }

    func discard() throws {}
}

private final class StubStaleDetector: CodexStaleClientDetecting {
    var observeCallCount = 0
    var observeLoginCallCount = 0
    var acknowledgeCallCount = 0
    var stubStale: CodexStaleClients?

    func observe(catalogURL: URL, catalogIsOurs: Bool) {
        observeCallCount += 1
    }

    func observeLogin(authURL: URL) {
        observeLoginCallCount += 1
    }

    func acknowledge(catalogURL: URL, authURL: URL) {
        acknowledgeCallCount += 1
    }

    func staleClients(catalogURL: URL, catalogIsOurs: Bool) async -> CodexStaleClients? {
        stubStale
    }
}

/// Claude 写入桩：digest 以「已应用过的发布模型 id 列表 + 成员开关」为磁盘现状口径——
/// 名单/开关不变 → 投影不变 → 跳过重写。
private final class StubClaudeWriter: AggregationClaudeConfigWriting {
    var lastAppliedPort: UInt16?
    var lastDefaultProfile: ProviderProfile?
    var lastMemberSwitches: [String: String]?
    var applyCount = 0
    var stubApplyError: Error?
    private var appliedPublished: [AggregationPublishedModel] = []
    private var appliedSwitches: [String: String] = [:]

    func applyAggregation(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) throws {
        if let stubApplyError { throw stubApplyError }
        lastAppliedPort = port
        lastDefaultProfile = defaultProfile
        lastMemberSwitches = memberSwitches
        appliedPublished = published
        appliedSwitches = memberSwitches
        applyCount += 1
    }

    func clearAggregation() throws {}

    func currentContractDigest() -> String {
        Self.digest(of: appliedPublished, switches: appliedSwitches)
    }

    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        published: [AggregationPublishedModel],
        port: UInt16,
        memberSwitches: [String: String]
    ) -> String {
        Self.digest(of: published, switches: memberSwitches)
    }

    private static func digest(of published: [AggregationPublishedModel], switches: [String: String]) -> String {
        published.map(\.id).joined(separator: "|") + "#"
            + switches.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
}

/// Codex 写入桩：口径同 Claude 桩。
private final class StubCodexWriter: AggregationCodexConfigWriting {
    var lastAppliedPort: UInt16?
    var lastDefaultProfile: ProviderProfile?
    var lastRequiresOpenAIAuth: Bool?
    var applyCount = 0
    var stubApplyError: Error?
    private var appliedPublished: [AggregationPublishedModel] = []

    func applyAggregation(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
    ) throws {
        if let stubApplyError { throw stubApplyError }
        lastAppliedPort = port
        lastDefaultProfile = defaultProfile
        lastRequiresOpenAIAuth = requiresOpenAIAuth
        appliedPublished = published
        applyCount += 1
    }

    func clearAggregation() throws {}

    func currentContractDigest() -> String {
        Self.digest(of: appliedPublished)
    }

    func projectedContractDigest(
        defaultProfile: ProviderProfile,
        defaultKey: String,
        published: [AggregationPublishedModel],
        port: UInt16,
        requiresOpenAIAuth: Bool,
    ) -> String {
        Self.digest(of: published)
    }

    private static func digest(of published: [AggregationPublishedModel]) -> String {
        published.map(\.id).joined(separator: "|")
    }
}
