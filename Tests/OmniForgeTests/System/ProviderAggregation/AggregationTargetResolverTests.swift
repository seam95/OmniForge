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
        XCTAssertEqual(resolver.resolve(tool: .codex, model: "om-kimi/kimi-k3"), .hit(target: kimiTarget, upstreamModel: "kimi-k3"))
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
