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

    /// 自锁修复（2026-10-18 实测现场）：第三方默认聚合期间官方登录被收纳——
    /// auth.json 不在场、只在 stash 里。「设为默认」的登录校验承认 stash 登录，
    /// 否则本应用自己收走的登录被自己的闸门判为未登录，官方永远无法上位。
    func test_setDefault_acceptsOfficialDefaultWhenLoginOnlyInStash() throws {
        profileStore.stubProfiles = [officialCodexProfile, thirdPartyCodexProfile]
        manager = makeManager()
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        // 模拟 stash() 之后的磁盘形态：原生登录已移走、只在 stash 里。
        loginStash.hasNativeLogin = false
        loginStash.hasStashedLogin = true

        try manager.setDefault("openai-official", tool: .codex)

        XCTAssertEqual(manager.toolStack(.codex).members.first, "openai-official")
        XCTAssertEqual(loginStash.restoreCallCount, 1, "校验放行后由官方分支还原收纳的登录")
    }

    /// 登录彻底不在场（auth.json 与 stash 都没有）→ 仍然事前挡下并指路。
    func test_setDefault_stillRejectsOfficialDefaultWhenLoginNowhere() throws {
        profileStore.stubProfiles = [officialCodexProfile, thirdPartyCodexProfile]
        manager = makeManager()
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")

        XCTAssertThrowsError(try manager.setDefault("openai-official", tool: .codex)) { error in
            XCTAssertEqual(error as? AggregationManagerError, .officialLoginRequired)
        }
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
        XCTAssertEqual(
            target.baseURL,
            AggregationUpstream.officialOAuthBaseURL,
            "OAuth token 只在 ChatGPT Codex 后端有效；转去 profile 的 api.openai.com 会 401"
        )
    }

    /// 第三方默认：不带透传位 —— 仍按占位凭证换成真实 token。
    func test_proxySnapshot_thirdPartyDefaultTargetKeepsCredentialRewrite() throws {
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")

        let target = try XCTUnwrap(manager.proxySnapshot().defaultTargets[.codex])
        XCTAssertFalse(target.passesThroughAuthorization)
        XCTAssertEqual(target.baseURL, "https://api.deepseek.com/v1", "第三方保留 profile 地址，不受官方后端规整影响")
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

    /// 官方卡不在名单时直接「设为默认」→ 分配 key 入座上位，原默认留在名单
    /// （官方进聚合只有默认位一条路，对齐 cc-switch「设默认一家还没添加的一并入名单」）。
    func test_setDefault_promotesNonMemberOfficialIntoStack() throws {
        profileStore.stubProfiles = [officialCodexProfile, thirdPartyCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true

        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        XCTAssertFalse(manager.toolStack(.codex).isMember("openai-official"), "前置：官方不在名单")

        try manager.setDefault("openai-official", tool: .codex)
        XCTAssertEqual(manager.toolStack(.codex).members.first, "openai-official", "官方上位为默认")
        XCTAssertEqual(manager.toolStack(.codex).members.contains("deepseek"), true, "原默认留在名单")
        XCTAssertNotNil(manager.toolStack(.codex).keyOf(profileID: "openai-official"), "官方一并分配 key")
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

    /// 回归：逐模型窗口与供应商级窗口都没配时，默认用 272K 工作窗口，
    /// 不再按 1M 发送；否则 128K/272K 的第三方模型会一直请求到上游拒绝。
    func test_codexPublishedModels_defaultsToWorkingWindow() throws {
        profileStore.stubProfiles = [
            ProviderProfile(
                id: "kimi", name: "Kimi", tool: .codex,
                baseURL: "https://api.kimi.com/v1", token: "sk-kimi",
                codexModels: ["kimi-k3"]
            )
        ]
        manager = makeManager()
        try manager.enterAggregation(tool: .codex, defaultProfileID: "kimi")
        let published = manager.publishedModels(tool: .codex)
        XCTAssertEqual(published.first?.window, CodexModelCatalogStore.aggregationWorkingWindow)
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

    // MARK: - 启动自愈

    /// 升级后首次启动：磁盘上的旧投影契约与当前口径不一致（官方默认带着占位
    /// bearer）→ recoverOnLaunch 必须补一次判变重写。缺了这一刀，名单没变时
    /// digest 闸门永远不触发，Codex 会一直拿占位符打官方上游 401。
    /// 桩的 `stubCurrentDigest` 模拟「磁盘还是旧契约」。
    func test_recoverOnLaunch_rewritesProjectionWhenDiskContractIsStale() throws {
        profileStore.stubProfiles = [officialCodexProfile]
        manager = makeManager()
        loginStash.hasNativeLogin = true
        try manager.enterAggregation(tool: .codex, defaultProfileID: "openai-official")
        try manager.setDefault("openai-official", tool: .codex)   // 先把契约刷到当前口径
        let writesBefore = codexWriter.applyCount

        codexWriter.stubCurrentDigest = "stale-old-shape"   // 磁盘仍是旧契约
        proxy.stop()                                        // 顺带覆盖「代理没在跑」分支
        manager.recoverOnLaunch()

        XCTAssertGreaterThan(codexWriter.applyCount, writesBefore, "启动自愈必须补一次投影重写")
        XCTAssertTrue(manager.isProxyRunning, "自愈前先确保代理在跑")
    }

    /// 契约未变（磁盘与当前口径一致）→ 启动自愈不重写，避免每次开应用都动用户配置。
    func test_recoverOnLaunch_skipsRewriteWhenContractUnchanged() throws {
        profileStore.stubProfiles = [thirdPartyCodexProfile]
        manager = makeManager()
        try manager.enterAggregation(tool: .codex, defaultProfileID: "deepseek")
        try manager.setDefault("deepseek", tool: .codex)   // applied 口径刷成当前投影
        let writesAfterEnter = codexWriter.applyCount

        manager.recoverOnLaunch()
        XCTAssertEqual(codexWriter.applyCount, writesAfterEnter, "契约未变不重写")
    }

    /// 聚合未启用的工具不受启动自愈影响（也不该被起代理）。
    func test_recoverOnLaunch_ignoresToolsWithoutAggregation() {
        manager.recoverOnLaunch()
        XCTAssertFalse(manager.isProxyRunning)
        XCTAssertEqual(codexWriter.applyCount, 0)
        XCTAssertEqual(claudeWriter.applyCount, 0)
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
    var hasStashedLogin = false
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
    /// 覆盖磁盘契约口径：模拟「磁盘上还是旧形态投影」（如升级前带着占位 bearer）。
    var stubCurrentDigest: String?
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
        stubCurrentDigest ?? Self.digest(of: appliedPublished)
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

// MARK: - Claude Desktop 聚合

extension ProviderAggregationManagerTests {
    private final class StubDesktopStore: ClaudeDesktopSettingsStoring {
        var lastApplyProfile: ProviderProfile?
        var lastApplyAggregation: (baseURL: String, token: String, models: [Any], discovery: Bool?)?
        var restoreOfficialCount = 0

        func applyProfile(_ profile: ProviderProfile, inferenceModels: [Any]?, modelDiscoveryEnabled: Bool?) throws {
            lastApplyProfile = profile
        }

        func applyAggregation(gatewayBaseURL: String, gatewayToken: String, inferenceModels: [Any], modelDiscoveryEnabled: Bool?) throws {
            lastApplyAggregation = (gatewayBaseURL, gatewayToken, inferenceModels, modelDiscoveryEnabled)
        }

        func restoreOfficial() throws {
            restoreOfficialCount += 1
        }

        func readState() throws -> ClaudeDesktopState {
            ClaudeDesktopState(deploymentMode: "1p", appliedId: nil, inferenceGatewayBaseUrl: nil, inferenceGatewayApiKey: nil, isOurProfileApplied: false)
        }

        func replayPendingIfPresent() throws -> Bool { false }

        func discardPending() throws {}
    }

    private func makeDesktopManager(
        desktopStore: StubDesktopStore,
        profiles: [ProviderProfile]
    ) -> ProviderAggregationManager {
        ProviderAggregationManager(
            profileStore: profileStore,
            backupStore: backupStore,
            stackStore: AggregationStackStore(stackURL: tmpDir.appendingPathComponent("stack-\(UUID().uuidString).json")),
            pendingStore: AggregationPendingStore(pendingURL: tmpDir.appendingPathComponent("pending-\(UUID().uuidString).json")),
            loginStashStore: loginStash,
            staleDetector: staleDetector,
            proxy: proxy,
            claudeWriter: claudeWriter,
            codexWriter: codexWriter,
            desktopWriter: nil,
            desktopStore: desktopStore,
            profiles: profiles
        )
    }

    private func makeDesktopProfile(
        id: String,
        routes: [String: DesktopModelRoute]?
    ) -> ProviderProfile {
        ProviderProfile(
            id: id, name: id, tool: .claudeDesktop,
            baseURL: "https://\(id).example/api/anthropic", token: "sk-\(id)",
            desktopModelRoutes: routes
        )
    }

    private var fourSlotRoutes: [String: DesktopModelRoute] {
        [
            "claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
            "claude-opus-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false),
        ]
    }

    /// 成员准入：无映射卡不进 joinable、addMember 拒绝并报错。
    func test_desktop_memberRequiresRoutes() throws {
        let mapping = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let direct = makeDesktopProfile(id: "relay", routes: nil)
        let store = StubDesktopStore()
        let manager = makeDesktopManager(desktopStore: store, profiles: [mapping, direct])

        XCTAssertEqual(manager.joinableProfileIDs(tool: .claudeDesktop), ["glm"], "无映射的直连卡不可加入")
        XCTAssertThrowsError(try manager.addMember("relay", tool: .claudeDesktop)) { error in
            XCTAssertEqual(error as? AggregationManagerError, .desktopRoutesRequired(id: "relay"))
        }
    }

    /// 进入聚合 + 成员发布去重（同家多档同 upstream 只发一条）。
    func test_desktop_enterAggregationPublishesDedupedModels() throws {
        let mapping = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let member = makeDesktopProfile(id: "kimi", routes: [
            "claude-sonnet-5": DesktopModelRoute(model: "k3", labelOverride: nil, supports1M: false),
            "claude-opus-5": DesktopModelRoute(model: "k3", labelOverride: nil, supports1M: false),
            "claude-haiku-4-5": DesktopModelRoute(model: "k3-flash", labelOverride: nil, supports1M: true),
        ])
        let store = StubDesktopStore()
        let manager = makeDesktopManager(desktopStore: store, profiles: [mapping, member])

        try manager.enterAggregation(tool: .claudeDesktop, defaultProfileID: "glm")
        try manager.addMember("kimi", tool: .claudeDesktop)

        let published = manager.publishedModels(tool: .claudeDesktop)
        // glm 的 sonnet/opus 都指 glm-5.3 → 去重后 1 条；kimi 的 k3 两档 → 1 条 + k3-flash 1 条。
        XCTAssertEqual(published.count, 3)
        let upstreams = Set(published.map(\.upstream))
        XCTAssertEqual(upstreams, ["glm-5.3", "k3", "k3-flash"])
        // 发布 id 为 Desktop 聚合编码形态。
        XCTAssertTrue(published.allSatisfy { $0.id.hasPrefix(AggregationModelID.desktopPrefix) })
        // 1M 合并：kimi haiku 档 supports1M → k3-flash 条目 oneM。
        XCTAssertTrue(published.first(where: { $0.upstream == "k3-flash" })?.oneM ?? false)
        // label 形态：供应商 / 模型名。
        XCTAssertTrue(published.contains { $0.label == "kimi / k3" })
    }

    /// 每工具独立：Desktop 进入聚合不影响 Claude Code 的直连状态。
    func test_desktop_aggregationIsPerTool() throws {
        let mapping = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let store = StubDesktopStore()
        let manager = makeDesktopManager(desktopStore: store, profiles: profileStore.stubProfiles + [mapping])

        try manager.enterAggregation(tool: .claudeDesktop, defaultProfileID: "glm")
        XCTAssertEqual(manager.mode(tool: .claudeDesktop), .aggregation)
        XCTAssertEqual(manager.mode(tool: .claudeCode), .direct, "Desktop 聚合不影响其它工具")
        XCTAssertEqual(manager.mode(tool: .codex), .direct)
    }

    /// 退出聚合：写默认那家 direct 形态（无 inferenceModels）。
    func test_desktop_exitAggregationWritesDefaultDirectProfile() throws {
        let mapping = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let store = StubDesktopStore()
        let manager = makeDesktopManager(desktopStore: store, profiles: [mapping])

        try manager.enterAggregation(tool: .claudeDesktop, defaultProfileID: "glm")
        try manager.exitAggregation(tool: .claudeDesktop)

        XCTAssertEqual(manager.mode(tool: .claudeDesktop), .direct)
        XCTAssertEqual(store.lastApplyProfile?.id, "glm", "退出写默认那家 direct 形态")
        XCTAssertEqual(store.restoreOfficialCount, 0)
    }

    /// 审查回归锁（跨工具串卡）：同名卡在两工具同时存在时，Desktop 发布表只能取 Desktop 的卡。
    /// 档案 id 只在单工具目录内唯一，漏 tool 过滤会取到 Claude Code 的卡 → 发布表为空。
    func test_desktop_publishedModelsDoNotPickOtherToolsCard() throws {
        // 同 id "glm" 的 Claude Code 卡排在 profiles 前面（制造无过滤时的错误命中）。
        let claudeCodeCard = ProviderProfile(
            id: "glm", name: "GLM", tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-cc",
            stackModels: [ClaudeStackModel(model: "glm-5.3", displayName: nil, oneM: false)]
        )
        let desktopCard = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let store = StubDesktopStore()
        let manager = makeDesktopManager(desktopStore: store, profiles: [claudeCodeCard, desktopCard])

        try manager.enterAggregation(tool: .claudeDesktop, defaultProfileID: "glm")
        let published = manager.publishedModels(tool: .claudeDesktop)
        XCTAssertFalse(published.isEmpty, "Desktop 发布表不得因同名卡排在前面而变空")
        XCTAssertTrue(published.allSatisfy { $0.tool == .claudeDesktop })
        XCTAssertTrue(published.allSatisfy { $0.id.hasPrefix(AggregationModelID.desktopPrefix) })
    }

    /// 审查回归锁：映射卡做默认那家时，退出聚合不得失败（映射卡不能走直连写入）。
    /// 有 bundle 快照 → 按快照恢复；无快照 → 恢复官方 1P（不尝试非法直连写入）。
    func test_desktop_exitAggregationWithMappingCardDefaultDoesNotThrow() throws {
        let mapping = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let store = StubDesktopStore()
        let manager = makeDesktopManager(desktopStore: store, profiles: [mapping])

        try manager.enterAggregation(tool: .claudeDesktop, defaultProfileID: "glm")
        XCTAssertNoThrow(try manager.exitAggregation(tool: .claudeDesktop))
        XCTAssertEqual(manager.mode(tool: .claudeDesktop), .direct)
        XCTAssertNil(store.lastApplyProfile, "映射卡不得走 applyProfile（会被白名单/守卫拒绝）")
        XCTAssertGreaterThanOrEqual(store.restoreOfficialCount, 1, "无快照时恢复官方 1P")
    }

    /// 默认那家被删后退出 → restoreOfficial 兜底。
    func test_desktop_exitAggregationFallsBackToOfficialWhenDefaultGone() throws {
        let mapping = makeDesktopProfile(id: "glm", routes: fourSlotRoutes)
        let store = StubDesktopStore()
        var profiles: [ProviderProfile] = profileStore.stubProfiles
        profiles.append(mapping)
        let manager = makeDesktopManager(desktopStore: store, profiles: profiles)

        try manager.enterAggregation(tool: .claudeDesktop, defaultProfileID: "glm")
        // 删掉默认那家再刷新：名单摘除已删卡 → 退出时无默认可写。
        profileStore.stubProfiles = profiles.filter { $0.id != "glm" }
        manager.refresh()
        try manager.exitAggregation(tool: .claudeDesktop)
        XCTAssertGreaterThanOrEqual(store.restoreOfficialCount, 1, "无默认那家 → 恢复官方兜底")
    }
}
