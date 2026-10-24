import XCTest
@testable import OmniForge

/// 目标解析：普通模型走默认、带前缀命中归属成员并还原上游名、1M 标记随行、
/// Codex 用裸名、四种 Miss 一律不回落到默认、双语文案含 OmniForge；
/// 官方透传位按**工具**分侧——Codex 官方透传客户端凭证，Claude 官方仍做凭证替换。
final class AggregationTargetResolverTests: XCTestCase {
    private var resolver: AggregationTargetResolver!
    private var registry: AggregationKeyRegistry!
    private var profiles: [ProviderProfile]!
    private var defaultTarget: AggregationProxyTarget!
    private var kimiTarget: AggregationProxyTarget!
    private var zhipuTarget: AggregationProxyTarget!

    override func setUp() {
        let kimi = ProviderProfile(
            id: "kimi",
            name: "Kimi For Coding",
            tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding",
            token: "sk-kimi",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "Kimi K3", oneM: false)]
        )
        let zhipu = ProviderProfile(
            id: "zhipu",
            name: "Zhipu",
            tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-zhipu",
            stackModels: [ClaudeStackModel(model: "glm-5.2", displayName: "GLM 5.2", oneM: true)],
            extraEnv: ["CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1000000"]
        )
        profiles = [kimi, zhipu]
        // "gone" 已登记但 profile 已删除 —— deleted 态fixture
        registry = AggregationKeyRegistry(keys: ["kimi": "kimi", "zhipu": "zhipu", "gone": "gone"])
        defaultTarget = AggregationProxyTarget(
            key: "deepseek", profileID: "deepseek",
            baseURL: "https://api.deepseek.com/anthropic", token: "sk-ds"
        )
        kimiTarget = AggregationProxyTarget(
            key: "kimi", profileID: "kimi",
            baseURL: "https://api.kimi.com/coding", token: "sk-kimi"
        )
        zhipuTarget = AggregationProxyTarget(
            key: "zhipu", profileID: "zhipu",
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-zhipu"
        )
        resolver = AggregationTargetResolver(
            stack: .init(enabled: true, members: ["kimi", "zhipu"], keys: ["kimi": "kimi", "zhipu": "zhipu", "gone": "gone"]),
            registry: registry,
            profiles: profiles,
            defaultTarget: defaultTarget
        )
    }

    func test_plainModelRoutesToDefault() {
        XCTAssertEqual(resolver.resolve(tool: .claudeCode, model: "claude-sonnet-4-6"), .plain(target: defaultTarget))
    }

    /// 解析器对 plain 目标只做透传：置位职责在 manager 构造 `defaultTarget` 时
    /// （按 `isOfficial`），resolver 原样带回传入目标身上的位，不自行判定。
    func test_plainTargetCarriesPassthroughBitFromInjectedDefault() {
        let passthroughDefault = AggregationProxyTarget(
            key: "deepseek", profileID: "deepseek",
            baseURL: "https://api.deepseek.com/anthropic", token: "",
            passesThroughAuthorization: true
        )
        let official = AggregationTargetResolver(
            stack: .init(enabled: true, members: ["kimi"], keys: ["kimi": "kimi"]),
            registry: registry,
            profiles: profiles,
            defaultTarget: passthroughDefault
        )
        XCTAssertEqual(official.resolve(tool: .claudeCode, model: "claude-sonnet-4-6"), .plain(target: passthroughDefault))
    }

    /// hit 目标随**命中那家**的官方性置位：第三方成员一律按占位凭证换成真实 token。
    func test_hitTargetOnThirdPartyMemberKeepsCredentialRewrite() {
        guard case .hit(let target, _) = resolver.resolve(tool: .claudeCode, model: "om-claude-kimi--k3") else {
            return XCTFail("expected hit")
        }
        XCTAssertEqual(target, kimiTarget)
        XCTAssertFalse(target.passesThroughAuthorization)
    }

    /// 官方那家入不了名单（`joinableProfileIDs` 排除官方），却能作为默认那家坐在
    /// `members[0]` 并分到 key、发布模型——它的 Stack id 同样可被命中（代理的模型发现
    /// 端点把全部成员的已发布模型都列出去）。命中 Codex 官方时必须透传：官方无静态 token，
    /// 换成空串只会 401（SPEC 3 契约 4「plain 与 hit 同规则」）。
    func test_hitTargetOnOfficialCodexMemberPassesAuthorizationThrough() {
        let official = ProviderProfile(
            id: "openai-official",
            name: "OpenAI",
            tool: .codex,
            baseURL: "https://api.openai.com/v1",
            token: "",
            codexModels: ["gpt-5-codex"]
        )
        let officialResolver = AggregationTargetResolver(
            stack: .init(enabled: true, members: ["openai-official"],
                         keys: ["openai-official": "openai-official"]),
            registry: AggregationKeyRegistry(keys: ["openai-official": "openai-official"]),
            profiles: [official],
            defaultTarget: defaultTarget
        )

        guard case .hit(let target, let upstreamModel) =
            officialResolver.resolve(tool: .codex, model: "om-openai-official/gpt-5-codex") else {
            return XCTFail("expected hit")
        }
        XCTAssertEqual(upstreamModel, "gpt-5-codex")
        XCTAssertEqual(target.token, "", "官方账号无静态 token（OAuth 走 auth.json）")
        XCTAssertTrue(target.passesThroughAuthorization, "命中 Codex 官方：客户端 Authorization 原样透传")
        XCTAssertEqual(
            target.baseURL,
            "https://chatgpt.com/backend-api/codex",
            "OAuth 凭证只对 ChatGPT Codex 后端有效；转发到 profile 写的 api.openai.com 只会 401"
        )
    }

    /// Claude 侧官方成员（api.anthropic.com）**不**透传：投影写死
    /// `ANTHROPIC_AUTH_TOKEN = PROXY_MANAGED`，透传等于把占位符发给 Anthropic → 每个请求 401。
    /// 官方 Anthropic 的数据模型形状是静态 API key，凭证照常替换（SPEC §3 收尾「Claude 侧不动」）。
    func test_hitTargetOnOfficialClaudeMemberKeepsCredentialRewrite() {
        let official = ProviderProfile(
            id: "anthropic-official",
            name: "Anthropic",
            tool: .claudeCode,
            baseURL: "https://api.anthropic.com",
            token: "sk-ant-official",
            stackModels: [ClaudeStackModel(model: "k3", displayName: "K3 K3", oneM: false)]
        )
        let officialResolver = AggregationTargetResolver(
            stack: .init(enabled: true, members: ["anthropic-official"],
                         keys: ["anthropic-official": "anthropic-official"]),
            registry: AggregationKeyRegistry(keys: ["anthropic-official": "anthropic-official"]),
            profiles: [official],
            defaultTarget: defaultTarget
        )

        guard case .hit(let target, let upstreamModel) =
            officialResolver.resolve(tool: .claudeCode, model: "om-claude-anthropic-official--k3") else {
            return XCTFail("expected hit")
        }
        XCTAssertEqual(upstreamModel, "k3")
        XCTAssertEqual(target.token, "sk-ant-official", "Claude 官方是静态 API key：替换用的真实凭证")
        XCTAssertFalse(target.passesThroughAuthorization, "Claude 侧不透传：否则占位 token 直达 Anthropic")
    }

    func test_prefixedModelHitsOwningMemberWithUpstreamNameRestored() {
        XCTAssertEqual(resolver.resolve(tool: .claudeCode, model: "om-claude-kimi--k3"), .hit(target: kimiTarget, upstreamModel: "k3"))
    }

    func test_oneMMarkerIsCarriedIntoUpstreamModelForClaude() {
        XCTAssertEqual(resolver.resolve(tool: .claudeCode, model: "om-claude-zhipu--glm-5.2[1M]"),
                       .hit(target: zhipuTarget, upstreamModel: "glm-5.2[1M]"))
    }

    func test_codexUpstreamModelIsBareModelName() {
        // Codex 解析必须配 Codex 卡：跨工具同名卡按 (id, tool) 限定后不再互相命中。
        let codexKimi = ProviderProfile(
            id: "kimi", name: "Kimi", tool: .codex,
            baseURL: "https://api.kimi.com/v1", token: "sk-kimi-codex",
            codexModels: ["kimi-k3"]
        )
        let codexResolver = AggregationTargetResolver(
            stack: .init(enabled: true, members: ["kimi"], keys: ["kimi": "kimi"]),
            registry: AggregationKeyRegistry(keys: ["kimi": "kimi"]),
            profiles: [codexKimi],
            defaultTarget: nil
        )
        XCTAssertEqual(
            codexResolver.resolve(tool: .codex, model: "om-kimi/kimi-k3"),
            .hit(
                target: AggregationProxyTarget(
                    key: "kimi", profileID: "kimi",
                    baseURL: "https://api.kimi.com/v1", token: "sk-kimi-codex"
                ),
                upstreamModel: "kimi-k3"
            )
        )
        // 同名跨工具不串：Claude 形态的 id 在 Codex 侧按 plain 走（无默认目标 → stackOff），
        // 无论如何不会命中 Claude 那张 kimi 卡。
        XCTAssertEqual(codexResolver.resolve(tool: .codex, model: "om-claude-kimi--k3"), .miss(.stackOff))
    }

    func test_malformedIDMissesAsUnknown() {
        XCTAssertEqual(resolver.resolve(tool: .claudeCode, model: "om-claude---k3"), .miss(.unknown))
    }

    func test_missWhenStackDisabledEvenThoughKeyIsRegistered() {
        let disabled = AggregationTargetResolver(stack: .init(enabled: false, members: ["kimi"], keys: ["kimi": "kimi"]),
                                                 registry: registry, profiles: profiles, defaultTarget: defaultTarget)
        XCTAssertEqual(disabled.resolve(tool: .claudeCode, model: "om-claude-kimi--k3"), .miss(.stackOff))
    }

    func test_missWhenKeyUnregistered() {
        XCTAssertEqual(resolver.resolve(tool: .claudeCode, model: "om-claude-nobody--x"), .miss(.unknown))
    }

    func test_missWhenMemberRemovedFromStack() {
        let shrunk = AggregationTargetResolver(stack: .init(enabled: true, members: [], keys: ["kimi": "kimi"]),
                                               registry: registry, profiles: profiles, defaultTarget: defaultTarget)
        XCTAssertEqual(shrunk.resolve(tool: .claudeCode, model: "om-claude-kimi--k3"), .miss(.removed))
    }

    func test_missWhenProfileDeleted() {
        XCTAssertEqual(resolver.resolve(tool: .claudeCode, model: "om-claude-gone--x"), .miss(.deleted))
    }

    func test_missNeverFallsBackToDefault() {
        for resolution in [resolver.resolve(tool: .claudeCode, model: "om-claude-nobody--x"),
                           resolver.resolve(tool: .claudeCode, model: "om-claude-gone--x")] {
            if case .miss = resolution { continue }
            XCTFail("expected miss, got \(resolution)")
        }
    }

    func test_missMessages_areBilingualAndMentionOmniForge() {
        for miss in [AggregationMiss.stackOff, .unknown, .removed, .deleted] {
            let message = miss.message(model: "om-claude-kimi--k3")
            XCTAssertTrue(message.contains("聚合的模型"))
            XCTAssertTrue(message.contains("OmniForge"))
            XCTAssertTrue(message.contains("("))
        }
    }
}

// MARK: - Desktop 聚合 id（.stackCode 发布表反查）

extension AggregationTargetResolverTests {
    private func makeDesktopFixture(
        enabled: Bool = true,
        members: [String] = ["glm"],
        published: [AggregationPublishedModel] = []
    ) -> (resolver: AggregationTargetResolver, entry: AggregationPublishedModel?) {
        let profile = ProviderProfile(
            id: "glm",
            name: "智谱",
            tool: .claudeDesktop,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-glm",
            desktopModelRoutes: ["claude-sonnet-5": DesktopModelRoute(model: "glm-5.3", labelOverride: nil, supports1M: false)]
        )
        let stack = AggregationStack.ToolStack(
            enabled: enabled, members: members, keys: ["glm": "glm"]
        )
        let entry = published.first ?? AggregationPublishedModel(
            tool: .claudeDesktop,
            key: "glm",
            profileName: "智谱",
            model: "glm-5.3",
            upstream: "glm-5.3",
            displayName: "GLM 5.3",
            oneM: false,
            window: 0
        )
        let resolver = AggregationTargetResolver(
            stack: stack,
            registry: AggregationKeyRegistry(keys: ["glm": "glm"]),
            profiles: [profile],
            defaultTarget: AggregationProxyTarget(
                key: "glm", profileID: "glm",
                baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
            ),
            published: [entry]
        )
        return (resolver, entry)
    }

    func test_desktopStackCodeHitsPublishedTableAndResolvesUpstream() {
        let (resolver, entry) = makeDesktopFixture()
        let entryID = entry!.id
        let target = AggregationProxyTarget(
            key: "glm", profileID: "glm",
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
        )
        XCTAssertEqual(
            resolver.resolve(tool: .claudeDesktop, model: entryID),
            .hit(target: target, upstreamModel: "glm-5.3")
        )
    }

    func test_desktopStackCodeMissesWhenTableEmpty() {
        let (resolver, entry) = makeDesktopFixture(published: [])
        // 发布表为空时任何 Desktop 聚合 id 都反查不到。
        let anyID = AggregationModelID.encode(tool: .claudeDesktop, key: "glm", model: "glm-5.3", oneM: false)
        _ = entry
        XCTAssertEqual(resolver.resolve(tool: .claudeDesktop, model: anyID), .miss(.unknown))
    }

    func test_desktopStackCodeMissesWhenStackDisabled() {
        let (resolver, entry) = makeDesktopFixture(enabled: false)
        XCTAssertEqual(resolver.resolve(tool: .claudeDesktop, model: entry!.id), .miss(.stackOff))
    }

    func test_desktopStackCodeMissesWhenProfileRemovedFromMembers() {
        let (resolver, entry) = makeDesktopFixture(members: [])
        XCTAssertEqual(resolver.resolve(tool: .claudeDesktop, model: entry!.id), .miss(.removed))
    }

    func test_desktopPlainModelRoutesToDefault() {
        let (resolver, _) = makeDesktopFixture()
        let target = AggregationProxyTarget(
            key: "glm", profileID: "glm",
            baseURL: "https://open.bigmodel.cn/api/anthropic", token: "sk-glm"
        )
        XCTAssertEqual(
            resolver.resolve(tool: .claudeDesktop, model: "claude-sonnet-5"),
            .plain(target: target)
        )
    }
}
