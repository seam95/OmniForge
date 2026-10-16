import Foundation

/// 代理目标 — 请求最终发往的那家供应商。
struct AggregationProxyTarget: Equatable {
    let key: String
    let profileID: String
    let baseURL: String
    let token: String
    /// 官方目标：客户端的 `Authorization` 原样透传，不换成 profile 的 token
    /// （官方账号无静态 token，SPEC 3 契约 4）。**仅 Codex 侧**（`tool == .codex`）：
    /// Codex 官方登录走 `auth.json` OAuth，客户端自己带着有效凭证；
    /// Claude 侧官方 Anthropic 走的是静态 API key，投影写的又是
    /// `ANTHROPIC_AUTH_TOKEN = PROXY_MANAGED`，一旦透传就把占位符发给 Anthropic → 401
    /// （SPEC §3 收尾「Claude 侧不动」：官方默认照 BASE_URL + token 替换路径）。
    /// 置位按**目标那家**的官方性判定（`ProviderProfile.isOfficial`，Models 层纯谓词）：
    /// plain 路径由 manager 构造 `defaultTarget` 时置好；hit 路径由 resolver 按命中的
    /// profile 自行置位——官方那家虽入不了名单（`joinableProfileIDs` 排除官方），却能作为
    /// **默认那家**坐在 `members[0]` 并分到 key，其 Stack id 同样可被命中，故 hit 并非恒第三方。
    var passesThroughAuthorization: Bool = false
}

/// 模型 id 解析结果。
enum AggregationResolution: Equatable {
    /// 普通模型名 → 默认供应商（请求体原样转发）。
    case plain(target: AggregationProxyTarget)
    /// 聚合模型命中 → 目标成员 + 还原后的上游模型名（体里 model 换成它再转发）。
    case hit(target: AggregationProxyTarget, upstreamModel: String)
    /// 解不出来 → 四种原因之一（不回落到默认）。
    case miss(AggregationMiss)
}

/// 目标解析边界。
protocol AggregationResolving {
    func resolve(tool: ProviderTool, model: String) -> AggregationResolution
}

/// 目标解析实现（对齐 cc-switch `mode::stack::resolve`）——纯值逻辑，无 I/O。
/// `stack` / `registry` 都是**该工具**的那份，由调用方按 `toolStack(tool)` 提供；
/// `profiles` 由 `ProviderProfileStore` 列举后注入（登记簿本身不持列表）。
final class AggregationTargetResolver: AggregationResolving {
    private let stack: AggregationStack.ToolStack
    private let registry: AggregationKeyRegistry
    private let profiles: [ProviderProfile]
    private let defaultTarget: AggregationProxyTarget?

    init(
        stack: AggregationStack.ToolStack,
        registry: AggregationKeyRegistry,
        profiles: [ProviderProfile],
        defaultTarget: AggregationProxyTarget?
    ) {
        self.stack = stack
        self.registry = registry
        self.profiles = profiles
        self.defaultTarget = defaultTarget
    }

    func resolve(tool: ProviderTool, model: String) -> AggregationResolution {
        switch AggregationModelID.decode(tool: tool, id: model) {
        case .plain:
            guard let defaultTarget else { return .miss(.stackOff) }
            return .plain(target: defaultTarget)
        case .malformed:
            return .miss(.unknown)
        case .stack(let key, let stackModel, let oneM):
            guard stack.enabled else { return .miss(.stackOff) }
            guard let profileID = registry.keys[key] else { return .miss(.unknown) }
            guard let profile = profiles.first(where: { $0.id == profileID }) else { return .miss(.deleted) }
            guard stack.isMember(profileID) else { return .miss(.removed) }
            // 官方那家也能被命中（它作为默认那家在 members[0]、分到 key、有已发布模型）：
            // 命中官方时同样透传客户端凭证，否则空 token 覆盖 → 401（SPEC 3 契约 4，
            // plain 与 hit 同规则）。判据是 Models 层的纯谓词 `ProviderProfile.isOfficial`。
            // 但透传只属于 Codex：Claude 侧官方默认仍按占位凭证替换（SPEC §3 收尾
            // 「Claude 侧不动」），否则 `Bearer PROXY_MANAGED` 直达 Anthropic。
            let target = AggregationProxyTarget(
                key: key,
                profileID: profileID,
                baseURL: profile.baseURL,
                token: profile.token,
                passesThroughAuthorization: tool == .codex && profile.isOfficial
            )
            return .hit(target: target, upstreamModel: upstreamModel(tool: tool, profile: profile, key: key, model: stackModel, oneM: oneM))
        }
    }

    /// 上游模型名：Codex 侧用裸模型名；Claude 侧在发布源里找**剥标记后**匹配的条目，
    /// 取其 `upstream`（可能带 `[1M]`）；找不到（成员发布源已变）则按 oneM 重建。
    private func upstreamModel(tool: ProviderTool, profile: ProviderProfile, key: String, model: String, oneM: Bool) -> String {
        switch tool {
        case .codex:
            return model
        case .claudeCode:
            if let published = AggregationModelPublisher.published(profile: profile, key: key)
                .first(where: { AggregationModelID.stripOneMMarker($0.upstream).model == model }) {
                return published.upstream
            }
            return oneM ? model + AggregationModelID.oneMMarker : model
        }
    }
}
